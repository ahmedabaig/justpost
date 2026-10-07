"""Phase 7: check a new image against the blueprint and the plan it was made from.

A vision model answers one yes/no/unsure question per blueprint and plan item,
with the reference slide for comparison. Code writes the questions, checks that
each one was answered exactly once, and decides the verdict from the answers;
the model is never asked whether the image is good overall. `unsure` counts as
a failure, so an image passes only when every deciding answer is the expected
one. The same reply marks the areas slide text must not cover.
"""

from __future__ import annotations

import time
from collections import Counter
from dataclasses import dataclass, field
from io import BytesIO
from typing import Any, Literal

from PIL import Image
from pydantic import ValidationError

from justpost.model_io import (
    MAX_ATTEMPTS,
    Attempt,
    CheckReport,
    VisionModel,
    failed,
    run_attempts,
    validation_issues,
    with_feedback,
)
from justpost.validation_schema import MAX_KEEP_CLEAR, SCHEMA_VERSION, CheckReply

Kind = Literal["required", "preferred", "forbidden", "change", "text_in_image", "artifacts"]
Status = Literal["passed", "rejected", "unverified"]

TEXT_IN_IMAGE = "text_in_image"
ARTIFACTS = "artifacts"
WEBP_QUALITY = 85

INSTRUCTIONS = f"""\
You check a newly generated image for a social-media slide. Image 1 is the \
reference slide that performed well. Image 2 is the new image, made to keep \
the reference's format while changing a few planned things. Slide text is \
added later by other software, so the new image should have none.

Answer every question in the list about image 2, using image 1 only for \
comparison. Answer "yes" or "no" when you can see the answer clearly, and \
"unsure" when you can't tell. Don't judge whether the image is attractive; \
only answer the questions. Add a short note saying what you saw.

Also list up to {MAX_KEEP_CLEAR} keep-clear areas in image 2: things that \
overlaid text must not cover, such as faces (including a graphic covering a \
face), the main product or held object, and other key visual devices. Give \
each a short label and a box as fractions of the image width and height, \
measured from the top-left corner. Use an empty list if nothing must stay \
clear.

Reply with a single JSON object and nothing else, in exactly this shape:

{{
  "schemaVersion": {SCHEMA_VERSION},
  "checks": [{{"id": "question id", "answer": "yes | no | unsure", "note": "..."}}],
  "keepClear": [{{"label": "face", "region": {{"x": 0.3, "y": 0.2, "w": 0.3, "h": 0.2}}}}]
}}\
"""


@dataclass(frozen=True)
class Question:
    id: str
    kind: Kind
    text: str
    subject: str
    # None means the answer is shown but doesn't decide the verdict.
    expected: Literal["yes", "no"] | None


_TEXT_QUESTION = Question(
    id=TEXT_IN_IMAGE,
    kind="text_in_image",
    text="Is there any visible text, lettering, caption, watermark or logo in image 2?",
    subject="text in the image",
    expected="no",
)
_ARTIFACTS_QUESTION = Question(
    id=ARTIFACTS,
    kind="artifacts",
    text=(
        "Are there major glitches in image 2, such as warped or extra fingers, a "
        "distorted face, melted or merged objects, or broken edges?"
    ),
    subject="visible glitches",
    expected="no",
)


def questions_for(blueprint: dict[str, Any], plan: dict[str, Any]) -> list[Question]:
    """Deciding questions first, then the preferred principles, shown for information."""

    def principles(section: str, kind: Kind, ask: str, expected) -> list[Question]:
        return [
            Question(f"{kind}:{item['id']}", kind, f"{ask} {item['text']}", item["text"], expected)
            for item in blueprint.get(section) or []
        ]

    names = {item["id"]: item["name"] for item in blueprint.get("variationDimensions") or []}
    changes = []
    for index, change in enumerate(plan.get("changes") or []):
        subject = f"{names.get(change['dimensionId'], change['dimensionId'])}: {change['value']}"
        changes.append(
            Question(
                f"change:{index + 1}",
                "change",
                f"Was this planned change made? {subject}",
                subject,
                "yes",
            )
        )
    return [
        *principles("requiredPrinciples", "required", "Is this still true?", "yes"),
        *principles("forbiddenDrift", "forbidden", "Has this happened?", "no"),
        *changes,
        _TEXT_QUESTION,
        _ARTIFACTS_QUESTION,
        *principles("preferredPrinciples", "preferred", "Is this still true?", None),
    ]


def build_instructions(previous_issues: tuple[str, ...] = ()) -> str:
    return with_feedback(INSTRUCTIONS, previous_issues)


def user_text_for(questions: list[Question]) -> str:
    listed = "\n".join(f"- {question.id}: {question.text}" for question in questions)
    return f"Questions about image 2, by id:\n{listed}"


def reason_for(question: Question, answer: str) -> str:
    """Why an answer fails the image, in words the app can show as they are."""
    unsure = answer == "unsure"
    prefixes = {
        "required": ("Missing", "Couldn't confirm"),
        "forbidden": ("Not allowed", "Couldn't rule out"),
        "change": ("Not changed", "Couldn't confirm the change"),
    }
    if question.kind in prefixes:
        prefix = prefixes[question.kind][1 if unsure else 0]
        return f"{prefix}: {question.subject}"
    if question.kind == "text_in_image":
        return (
            "Couldn't rule out text in the image."
            if unsure
            else "The image has its own text in it."
        )
    return "Couldn't rule out visible glitches." if unsure else "The image has visible glitches."


@dataclass(frozen=True)
class Verdict:
    passed: bool
    checks: list[dict[str, Any]]
    reasons: list[str]
    keep_clear: list[dict[str, Any]]


def check_reply(
    data: dict[str, Any], questions: list[Question]
) -> tuple[Verdict | None, CheckReport]:
    """Checks the reply's shape and coverage; the verdict comes from the answers."""
    try:
        reply = CheckReply.model_validate(data)
    except ValidationError as error:
        return None, failed(*validation_issues(error))

    by_id = {question.id: question for question in questions}
    counts = Counter(check.id for check in reply.checks)
    issues = [f"'{check_id}' is answered more than once." for check_id, n in counts.items() if n > 1]
    issues += [f"'{check_id}' is not one of the questions." for check_id in counts if check_id not in by_id]
    issues += [f"'{question.id}' has no answer." for question in questions if question.id not in counts]
    if issues:
        return None, failed(*issues)

    answers = {check.id: check for check in reply.checks}
    checks: list[dict[str, Any]] = []
    reasons: list[str] = []
    for question in questions:
        answer = answers[question.id]
        passed = None if question.expected is None else answer.answer == question.expected
        if passed is False:
            reasons.append(reason_for(question, answer.answer))
        checks.append(
            {
                "id": question.id,
                "kind": question.kind,
                "question": question.text,
                "answer": answer.answer,
                "note": answer.note,
                "passed": passed,
            }
        )
    keep_clear = [area.model_dump() for area in reply.keepClear]
    verdict = Verdict(passed=not reasons, checks=checks, reasons=reasons, keep_clear=keep_clear)
    return verdict, CheckReport(passed=True)


def to_webp(png: bytes) -> bytes:
    image = Image.open(BytesIO(png)).convert("RGB")
    buffer = BytesIO()
    image.save(buffer, "WEBP", quality=WEBP_QUALITY)
    return buffer.getvalue()


@dataclass(frozen=True)
class ValidationOutcome:
    attempts: list[Attempt] = field(default_factory=list)
    verdict: Verdict | None = None
    latency_ms: int = 0

    @property
    def status(self) -> Status:
        if self.verdict is None:
            return "unverified"
        return "passed" if self.verdict.passed else "rejected"

    @property
    def reasons(self) -> list[str]:
        if self.verdict is None:
            return ["The image couldn't be checked."]
        return self.verdict.reasons

    def to_record(self) -> dict[str, Any]:
        verdict = self.verdict
        return {
            "model": next((a.model for a in self.attempts if a.model), None),
            "status": self.status,
            "checks": verdict.checks if verdict else [],
            "reasons": self.reasons,
            "keepClear": verdict.keep_clear if verdict else [],
            "attempts": [attempt.to_record() for attempt in self.attempts],
            "latencyMs": self.latency_ms,
            "inputTokens": sum(a.input_tokens or 0 for a in self.attempts),
            "outputTokens": sum(a.output_tokens or 0 for a in self.attempts),
        }


def validate(
    model: VisionModel,
    blueprint: dict[str, Any],
    plan: dict[str, Any],
    reference_webp: bytes,
    image_png: bytes,
    attempts: int = MAX_ATTEMPTS,
) -> ValidationOutcome:
    questions = questions_for(blueprint, plan)
    started = time.monotonic()
    outcome = run_attempts(
        model,
        build_instructions,
        user_text_for(questions),
        reference_webp,
        lambda data: check_reply(data, questions),
        attempts=attempts,
        extra_images=(to_webp(image_png),),
    )
    return ValidationOutcome(
        attempts=outcome.attempts,
        verdict=outcome.result,
        latency_ms=int((time.monotonic() - started) * 1000),
    )
