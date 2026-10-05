"""Phase 2: ask a vision model what a reference slide is doing, then check it.

Pure functions; the model and retry plumbing live in model_io.py. Raw model
text is kept for inspection only; the only result is an analysis that passed
`check_analysis`.
"""

from __future__ import annotations

import re
from typing import Any

from pydantic import ValidationError

from justpost.analysis_schema import SCHEMA_VERSION, CreativeAnalysis
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

# Observation must not turn into policy; that is Phase 3's job.
_PRESCRIPTIVE = re.compile(
    r"\b(must|should|has to|have to|needs? to|never change|do not change|don't change|"
    r"cannot change|can't change|keep (?:it|this|them)? ?the same|preserved?|"
    r"may (?:vary|change)|can (?:vary|change|be changed)|locked)\b",
    re.IGNORECASE,
)

USER_TEXT = "Analyze this slide."

INSTRUCTIONS = f"""\
You are analyzing a social-media slide so that another system can later create \
variations of it. Describe the creative structure of the image rather than \
merely captioning it.

Only observe. Do not write rules about what must stay the same or what may \
change; another step decides that.

Reply with a single JSON object and nothing else, in exactly this shape:

{{
  "schemaVersion": {SCHEMA_VERSION},
  "creativeType": "short label, e.g. ugc_hook_slide",
  "scene": {{
    "environment": "...", "lighting": "...", "background": "...",
    "cameraStyle": "..."
  }},
  "subjects": [{{
    "description": "...", "position": "...", "styling": ["..."],
    "faceVisibility": "visible | partial | obscured | not_shown",
    "holding": "... or null",
    "region": {{"x": 0.0, "y": 0.0, "w": 0.0, "h": 0.0}}
  }}],
  "visualDevices": [{{
    "type": "...", "description": "...", "role": "what it does for the creative",
    "region": {{"x": 0.0, "y": 0.0, "w": 0.0, "h": 0.0}}
  }}],
  "copy": [{{
    "text": "the exact visible text",
    "role": "hook | supporting | call_to_action | caption | label | other",
    "region": {{"x": 0.0, "y": 0.0, "w": 0.0, "h": 0.0}}
  }}],
  "hookType": "e.g. how-to, listicle, confession, or null if there is no hook",
  "mechanisms": ["why the hook or image grabs attention"],
  "composition": {{
    "orientation": "portrait | landscape | square",
    "subjectWeight": "...", "textPlacement": "...",
    "visualHierarchy": ["what the eye reaches first", "then second", "..."]
  }},
  "aesthetic": ["..."],
  "centralElements": ["elements that carry the creative idea"]
}}

Regions are fractions of the slide's width and height measured from the \
top-left corner, between 0 and 1. Use empty lists when something is absent.\
"""


def build_instructions(previous_issues: tuple[str, ...] = ()) -> str:
    return with_feedback(INSTRUCTIONS, previous_issues)


def _prescriptive_fields(value: Any, path: str = "") -> list[str]:
    """Paths of descriptive strings that state rules instead of observations."""
    if isinstance(value, dict):
        return [
            hit
            for key, item in value.items()
            # The slide's own words may say anything.
            if not (path.startswith("copy.") and key == "text")
            for hit in _prescriptive_fields(item, f"{path}.{key}" if path else key)
        ]
    if isinstance(value, list):
        return [
            hit
            for index, item in enumerate(value)
            for hit in _prescriptive_fields(item, f"{path}.{index}")
        ]
    if isinstance(value, str) and _PRESCRIPTIVE.search(value):
        return [path]
    return []


def check_analysis(
    data: dict[str, Any], expected_orientation: str | None = None
) -> tuple[CreativeAnalysis | None, CheckReport]:
    try:
        analysis = CreativeAnalysis.model_validate(data)
    except ValidationError as error:
        return None, failed(*validation_issues(error))

    issues = [
        f"{path}: states a rule instead of describing the slide"
        for path in _prescriptive_fields(analysis.model_dump(by_alias=True))
    ]
    if expected_orientation and analysis.composition.orientation != expected_orientation:
        issues.append(
            f"composition.orientation: says {analysis.composition.orientation} "
            f"but the slide is {expected_orientation}"
        )
    if issues:
        return None, failed(*issues[:MAX_ISSUES])
    return analysis, CheckReport(passed=True)


def analyze(
    image_webp: bytes,
    model: VisionModel,
    expected_orientation: str | None = None,
    attempts: int = MAX_ATTEMPTS,
) -> AttemptsOutcome[dict[str, Any]]:
    """Returns every attempt, plus the first analysis that passed as a dict."""

    def check(data: dict[str, Any]) -> tuple[dict[str, Any] | None, CheckReport]:
        analysis, report = check_analysis(data, expected_orientation)
        return (analysis.model_dump(by_alias=True) if analysis else None), report

    return run_attempts(model, build_instructions, USER_TEXT, image_webp, check, attempts)
