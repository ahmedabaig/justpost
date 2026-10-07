"""Phase 4: turn a confirmed blueprint into distinct variation plans, then check them.

The model writes the plans from the blueprint, the analysis and the image.
Code, not the model, assigns plan IDs, origins and the blueprint version and
analysis the plans belong to, and checks that every change uses one of the
blueprint's "can vary" dimensions. User edits go through the same checks with
looser limits.
"""

from __future__ import annotations

import copy
import json
import re
from typing import Any, Literal

from pydantic import ValidationError

from justpost.blueprint import similar, word_set
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
from justpost.plan_schema import (
    AI_MAX_CHANGES,
    AI_MIN_CHANGES,
    MAX_HOOK_CHARS,
    MAX_PLANS,
    MIN_PLANS,
    SCHEMA_VERSION,
    PlanSet,
    VariationPlan,
)

Source = Literal["ai", "user"]

MAX_HOOK_SENTENCES = 3
_SENTENCE_END = re.compile(r"[.!?]+(?=\s|$)")

INSTRUCTIONS = f"""\
You are planning new variations of a social-media slide that performed well. \
Each plan describes one new slide that still belongs to the same winning \
creative family but is not a copy of the original. Images are made later \
from your plans, so be concrete.

You get the slide image, a checked analysis of it as JSON, and its confirmed \
creative blueprint as JSON. The blueprint lists what must stay true \
("requiredPrinciples"), what is nice to keep ("preferredPrinciples"), what may \
change ("variationDimensions", each with an "id"), and what must never happen \
("forbiddenDrift").

Rules for every plan:
- Change between {AI_MIN_CHANGES} and {AI_MAX_CHANGES} of the variation \
dimensions, never all of them at once. Refer to each by its "id" and give the \
new value, for example {{"dimensionId": "var2", "value": "iced coffee"}}.
- Only change dimensions listed in "variationDimensions". Keep every required \
principle true and avoid everything in "forbiddenDrift".
- Write new slide text that follows the blueprint's "copyStrategy". Don't \
reuse the original text word for word. One line, at most {MAX_HOOK_CHARS} \
characters and {MAX_HOOK_SENTENCES} sentences. If the copy role is "none", \
set "copy" to null.
- Plans must clearly differ from each other in their changes and their text.

Reply with a single JSON object and nothing else, in exactly this shape:

{{
  "schemaVersion": {SCHEMA_VERSION},
  "plans": [
    {{
      "title": "short label, e.g. Cozy coffee run",
      "changes": [{{"dimensionId": "...", "value": "..."}}],
      "copy": {{"text": "...", "pattern": "hook style, e.g. POV or how-to"}}
    }}
  ]
}}\
"""


def build_instructions(previous_issues: tuple[str, ...] = ()) -> str:
    return with_feedback(INSTRUCTIONS, previous_issues)


def user_text_for(blueprint: dict[str, Any], analysis: dict[str, Any], count: int) -> str:
    def block(value: dict[str, Any]) -> str:
        return f"```json\n{json.dumps(value, indent=2, ensure_ascii=False)}\n```"

    plural = "plan" if count == 1 else "plans"
    return (
        f"Write exactly {count} variation {plural}.\n\n"
        f"Confirmed blueprint:\n{block(blueprint)}\n\n"
        f"Checked analysis of the attached slide:\n{block(analysis)}"
    )


def stamp_ai_draft(
    data: dict[str, Any], analysis_run_id: str, blueprint_version: int
) -> dict[str, Any]:
    """Adds the fields code owns: plan IDs, `origin: ai`, the blueprint version and run."""
    stamped = copy.deepcopy(data)
    stamped["analysisRunId"] = analysis_run_id
    stamped["blueprintVersion"] = blueprint_version
    plans = stamped.get("plans")
    if isinstance(plans, list):
        for index, plan in enumerate(plans):
            if isinstance(plan, dict):
                plan["id"] = f"p{index + 1}"
                plan["origin"] = "ai"
    return stamped


def change_limits(dimension_count: int, source: Source) -> tuple[int, int]:
    """The fewest and most changes a plan may make, given the blueprint's dimensions."""
    if source == "user":
        return 1, dimension_count
    if dimension_count < 3:
        return min(AI_MIN_CHANGES, dimension_count), dimension_count
    return AI_MIN_CHANGES, min(AI_MAX_CHANGES, dimension_count - 1)


def _plan_words(plan: VariationPlan) -> frozenset[str]:
    parts = [f"{change.dimensionId} {change.value}" for change in plan.changes]
    if plan.plan_copy:
        parts.append(plan.plan_copy.text)
    return word_set(" ".join(parts))


def copy_issues(where: str, text: str) -> list[str]:
    issues = []
    if "\n" in text or "\r" in text:
        issues.append(f"{where}.copy.text: keep it to one line")
    if len(_SENTENCE_END.findall(text)) > MAX_HOOK_SENTENCES:
        issues.append(f"{where}.copy.text: at most {MAX_HOOK_SENTENCES} sentences")
    return issues


def check_plans(
    data: dict[str, Any],
    blueprint: dict[str, Any],
    blueprint_version: int,
    analysis_run_id: str,
    source: Source,
    expected_count: int | None = None,
) -> tuple[PlanSet | None, CheckReport]:
    try:
        plan_set = PlanSet.model_validate(data)
    except ValidationError as error:
        return None, failed(*validation_issues(error))

    issues: list[str] = []
    if plan_set.blueprintVersion != blueprint_version:
        issues.append(
            "blueprintVersion: written for an earlier blueprint; plan again"
        )
    if plan_set.analysisRunId != analysis_run_id:
        issues.append("analysisRunId: written for an earlier analysis; plan again")

    count = len(plan_set.plans)
    if expected_count is not None and count != expected_count:
        issues.append(f"plans: write exactly {expected_count}, not {count}")
    elif not MIN_PLANS <= count <= MAX_PLANS:
        issues.append(f"plans: keep between {MIN_PLANS} and {MAX_PLANS}")

    dimensions = {item["id"] for item in blueprint.get("variationDimensions") or []}
    never = [
        (item["id"], word_set(item["text"])) for item in blueprint.get("forbiddenDrift") or []
    ]
    copy_role = (blueprint.get("copyStrategy") or {}).get("role", "none")
    fewest, most = change_limits(len(dimensions), source)

    seen_ids: set[str] = set()
    seen_plans: list[tuple[str, frozenset[str]]] = []
    for index, plan in enumerate(plan_set.plans):
        where = f"plans.{index}"
        if plan.id in seen_ids:
            issues.append(f"{where}.id: '{plan.id}' is used twice")
        seen_ids.add(plan.id)

        changed = len(plan.changes)
        if not fewest <= changed <= most:
            limit = str(fewest) if fewest == most else f"{fewest} to {most}"
            issues.append(f"{where}.changes: change {limit} dimensions, not {changed}")

        used: set[str] = set()
        for change_index, change in enumerate(plan.changes):
            change_where = f"{where}.changes.{change_index}"
            if change.dimensionId not in dimensions:
                issues.append(
                    f"{change_where}.dimensionId: '{change.dimensionId}' is not a "
                    "'can vary' dimension in the blueprint"
                )
            elif change.dimensionId in used:
                issues.append(
                    f"{change_where}.dimensionId: '{change.dimensionId}' is changed twice"
                )
            used.add(change.dimensionId)
            value_words = word_set(change.value)
            for never_id, never_words in never:
                if similar(value_words, never_words):
                    issues.append(f"{change_where}.value: matches 'never' item {never_id}")
                    break

        if copy_role == "none" and plan.plan_copy is not None:
            issues.append(f"{where}.copy: the blueprint has no copy role, so use null")
        elif copy_role != "none" and plan.plan_copy is None:
            issues.append(f"{where}.copy: write the slide text for this plan")
        elif plan.plan_copy is not None:
            issues.extend(copy_issues(where, plan.plan_copy.text))

        words = _plan_words(plan)
        for other_where, other_words in seen_plans:
            if similar(words, other_words):
                issues.append(f"{where}: too close to {other_where}")
                break
        seen_plans.append((where, words))

    if issues:
        return None, failed(*issues[:MAX_ISSUES])
    return plan_set, CheckReport(passed=True)


def dump(plan_set: PlanSet) -> dict[str, Any]:
    return plan_set.model_dump(by_alias=True)


def plan(
    blueprint: dict[str, Any],
    blueprint_version: int,
    analysis: dict[str, Any],
    analysis_run_id: str,
    count: int,
    image_webp: bytes,
    model: VisionModel,
    attempts: int = MAX_ATTEMPTS,
) -> AttemptsOutcome[dict[str, Any]]:
    """Returns every attempt, plus the first plan set that passed as a dict."""

    def check(data: dict[str, Any]) -> tuple[dict[str, Any] | None, CheckReport]:
        stamped = stamp_ai_draft(data, analysis_run_id, blueprint_version)
        plan_set, report = check_plans(
            stamped, blueprint, blueprint_version, analysis_run_id, "ai", count
        )
        return (dump(plan_set) if plan_set else None), report

    return run_attempts(
        model,
        build_instructions,
        user_text_for(blueprint, analysis, count),
        image_webp,
        check,
        attempts,
    )
