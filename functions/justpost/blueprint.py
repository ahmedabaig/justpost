"""Phase 3: turn a checked analysis into the slide's creative DNA, then check it.

The model proposes a draft from the analysis and the image. Code, not the
model, assigns item IDs, origins and the analysis the draft belongs to, and
checks that every item is grounded in the analysis. User edits go through the
same checks with looser minimums.
"""

from __future__ import annotations

import copy
import json
import re
from typing import Any, Literal

from pydantic import ValidationError

from justpost.blueprint_schema import MIN_ITEMS, SCHEMA_VERSION, SECTIONS, Blueprint
from justpost.model_io import (
    MAX_ATTEMPTS,
    MAX_ISSUES,
    AttemptsOutcome,
    CheckReport,
    VisionModel,
    failed,
    run_attempts,
    validation_issues,
    with_feedback,
)

Source = Literal["ai", "user"]

SECTION_LABELS = {
    "requiredPrinciples": "must keep",
    "preferredPrinciples": "nice to keep",
    "variationDimensions": "can vary",
    "forbiddenDrift": "never",
}
_ID_PREFIX = {
    "requiredPrinciples": "req",
    "preferredPrinciples": "pref",
    "variationDimensions": "var",
    "forbiddenDrift": "never",
}
_STOPWORDS = frozenset(
    "a an and the of in on to is are be with for or its it their this that".split()
)
NEAR_DUPLICATE = 0.8

INSTRUCTIONS = f"""\
You are building a creative blueprint for a social-media slide that performed \
well. Another system will use it to create new variations that still belong to \
the same winning creative family without copying the original.

You get the slide image and a checked analysis of it as JSON. Decide which \
parts make the format work. Do not list every detail: a green cup probably \
doesn't matter; a deliberately hidden face might.

Sections:
- requiredPrinciples: what must remain true for a variation to still belong \
to this family (3 to 10).
- preferredPrinciples: helpful but optional (0 to 8).
- variationDimensions: what can change between variations, with a few example \
values each (3 to 12).
- forbiddenDrift: changes that would break the format (2 to 8).
- copyStrategy: how the slide's text works. "role" must be one of the roles \
used in the analysis's "copy" list, or "none" if that list is empty.

Every principle and dimension must cite "basis": one or more paths into the \
analysis JSON that it comes from, using dots and list indexes, for example \
"subjects.0.faceVisibility", "copy.0", "visualDevices.1.role" or "scene". \
Only cite paths that exist in the analysis. Don't repeat the same idea in two \
sections.

Reply with a single JSON object and nothing else, in exactly this shape:

{{
  "schemaVersion": {SCHEMA_VERSION},
  "creativeFamily": "short label, e.g. ugc_car_selfie_hook",
  "objective": "what the slide is trying to achieve, in one sentence",
  "requiredPrinciples": [{{"text": "...", "basis": ["..."]}}],
  "preferredPrinciples": [{{"text": "...", "basis": ["..."]}}],
  "variationDimensions": [
    {{"name": "...", "examples": ["...", "..."], "basis": ["..."]}}
  ],
  "forbiddenDrift": [{{"text": "...", "basis": ["..."]}}],
  "copyStrategy": {{
    "role": "hook | supporting | call_to_action | caption | label | other | none",
    "primaryPattern": "...",
    "secondaryPattern": "... or null"
  }}
}}\
"""


def build_instructions(previous_issues: tuple[str, ...] = ()) -> str:
    return with_feedback(INSTRUCTIONS, previous_issues)


def user_text_for(analysis: dict[str, Any]) -> str:
    return (
        "Checked analysis of the attached slide:\n```json\n"
        f"{json.dumps(analysis, indent=2, ensure_ascii=False)}\n```"
    )


def stamp_ai_draft(data: dict[str, Any], analysis_run_id: str) -> dict[str, Any]:
    """Adds the fields code owns: item IDs, `origin: ai` and the analysis run."""
    stamped = copy.deepcopy(data)
    stamped["analysisRunId"] = analysis_run_id
    for section, prefix in _ID_PREFIX.items():
        items = stamped.get(section)
        if not isinstance(items, list):
            continue
        for index, item in enumerate(items):
            if isinstance(item, dict):
                item["id"] = f"{prefix}{index + 1}"
                item["origin"] = "ai"
    return stamped


def path_exists(data: Any, path: str) -> bool:
    node = data
    for part in path.split("."):
        if isinstance(node, dict) and part in node:
            node = node[part]
        elif isinstance(node, list) and part.isdigit() and int(part) < len(node):
            node = node[int(part)]
        else:
            return False
    return True


def word_set(text: str) -> frozenset[str]:
    return frozenset(re.findall(r"[a-z0-9]+", text.lower())) - _STOPWORDS


def similar(a: frozenset[str], b: frozenset[str]) -> bool:
    if not a or not b:
        return a == b
    return len(a & b) / len(a | b) >= NEAR_DUPLICATE


def _items(blueprint: Blueprint, section: str) -> list[Any]:
    return getattr(blueprint, section)


def _item_text(item: Any) -> str:
    return getattr(item, "text", None) or item.name


def check_blueprint(
    data: dict[str, Any],
    analysis: dict[str, Any],
    analysis_run_id: str,
    source: Source,
) -> tuple[Blueprint | None, CheckReport]:
    try:
        blueprint = Blueprint.model_validate(data)
    except ValidationError as error:
        return None, failed(*validation_issues(error))

    issues: list[str] = []
    if blueprint.analysisRunId != analysis_run_id:
        issues.append(
            "analysisRunId: built from an earlier analysis; rebuild the draft"
        )

    for section, minimum in MIN_ITEMS[source].items():
        count = len(_items(blueprint, section))
        if count < minimum:
            issues.append(
                f"{section}: needs at least {minimum} "
                f"'{SECTION_LABELS[section]}' item{'s' if minimum > 1 else ''}"
            )

    seen_ids: set[str] = set()
    seen_texts: list[tuple[str, frozenset[str]]] = []
    for section in SECTIONS:
        for index, item in enumerate(_items(blueprint, section)):
            where = f"{section}.{index}"
            if item.id in seen_ids:
                issues.append(f"{where}.id: '{item.id}' is used twice")
            seen_ids.add(item.id)

            if source == "ai" and not item.basis:
                issues.append(f"{where}.basis: cite at least one analysis path")
            for path in item.basis:
                if not path_exists(analysis, path):
                    issues.append(f"{where}.basis: '{path}' is not in the analysis")

            words = word_set(_item_text(item))
            for other_where, other_words in seen_texts:
                if similar(words, other_words):
                    issues.append(f"{where}: repeats {other_where}")
                    break
            seen_texts.append((where, words))

    copy_roles = {block.get("role") for block in analysis.get("copy") or []}
    role = blueprint.copyStrategy.role
    if copy_roles and role not in copy_roles:
        issues.append(
            f"copyStrategy.role: '{role}' is not a role used on the slide "
            f"({', '.join(sorted(r for r in copy_roles if r))})"
        )
    if not copy_roles and role != "none":
        issues.append("copyStrategy.role: the slide has no text, so use 'none'")

    if issues:
        return None, failed(*issues[:MAX_ISSUES])
    return blueprint, CheckReport(passed=True)


def build(
    analysis: dict[str, Any],
    analysis_run_id: str,
    image_webp: bytes,
    model: VisionModel,
    attempts: int = MAX_ATTEMPTS,
) -> AttemptsOutcome[dict[str, Any]]:
    """Returns every attempt, plus the first draft that passed as a dict."""

    def check(data: dict[str, Any]) -> tuple[dict[str, Any] | None, CheckReport]:
        stamped = stamp_ai_draft(data, analysis_run_id)
        blueprint, report = check_blueprint(stamped, analysis, analysis_run_id, "ai")
        return (blueprint.model_dump() if blueprint else None), report

    return run_attempts(
        model, build_instructions, user_text_for(analysis), image_webp, check, attempts
    )
