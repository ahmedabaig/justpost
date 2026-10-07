"""Shared plumbing for model steps: replies, attempts, checks and retries.

A model is any object with `respond(instructions, user_text, image_webp)`, so
each step's checks run without Firebase or OpenAI. Raw model text is kept for
inspection only; a step's result is whatever its check function approved.
"""

from __future__ import annotations

import json
import re
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from typing import Any, Generic, Protocol, TypeVar

from pydantic import ValidationError

MAX_ATTEMPTS = 2
MAX_RAW_CHARS = 20_000
MAX_ISSUES = 12

_FENCE = re.compile(r"^```(?:json)?[ \t]*\n(?P<body>.*)\n```$", re.DOTALL | re.IGNORECASE)

T = TypeVar("T")


class ModelError(RuntimeError):
    """The model could not be reached or returned no usable reply."""


@dataclass(frozen=True)
class ModelReply:
    text: str
    model: str
    refusal: bool = False
    input_tokens: int | None = None
    output_tokens: int | None = None


class VisionModel(Protocol):
    def respond(
        self,
        instructions: str,
        user_text: str,
        image_webp: bytes,
        extra_images: Sequence[bytes] = (),
    ) -> ModelReply: ...


class ModelRefusal(ModelError):
    """The model declined the request, for example for content-safety reasons."""


@dataclass(frozen=True)
class ImageReply:
    image: bytes
    model: str
    input_tokens: int | None = None
    output_tokens: int | None = None


class ImageModel(Protocol):
    def edit(self, request: str, reference_webp: bytes, size: str) -> ImageReply: ...


@dataclass(frozen=True)
class CheckReport:
    passed: bool
    issues: tuple[str, ...] = ()

    @property
    def status(self) -> str:
        return "passed" if self.passed else "failed"


def failed(*issues: str) -> CheckReport:
    return CheckReport(passed=False, issues=tuple(issues[:MAX_ISSUES]))


def validation_issues(error: ValidationError) -> tuple[str, ...]:
    def describe(item: dict[str, Any]) -> str:
        location = ".".join(str(part) for part in item["loc"]) or "reply"
        return f"{location}: {item['msg']}"

    return tuple(describe(item) for item in error.errors()[:MAX_ISSUES])


@dataclass(frozen=True)
class Attempt:
    raw_text: str
    report: CheckReport
    model: str | None
    latency_ms: int
    input_tokens: int | None = None
    output_tokens: int | None = None

    def to_record(self) -> dict[str, Any]:
        return {
            "rawText": self.raw_text,
            "status": self.report.status,
            "issues": list(self.report.issues),
            "model": self.model,
            "latencyMs": self.latency_ms,
            "inputTokens": self.input_tokens,
            "outputTokens": self.output_tokens,
        }


@dataclass(frozen=True)
class AttemptsOutcome(Generic[T]):
    attempts: list[Attempt] = field(default_factory=list)
    result: T | None = None

    @property
    def passed(self) -> bool:
        return self.result is not None


def with_feedback(instructions: str, previous_issues: tuple[str, ...]) -> str:
    """Appends the previous attempt's failures so a retry can fix them."""
    if not previous_issues:
        return instructions
    listed = "\n".join(f"- {issue}" for issue in previous_issues)
    return (
        f"{instructions}\n\nYour previous answer failed these checks; fix them "
        f"and reply with the corrected JSON only:\n{listed}"
    )


def parse_raw(text: str) -> tuple[dict[str, Any] | None, tuple[str, ...]]:
    """Parses a reply that is a JSON object, optionally inside one code fence."""
    body = text.strip()
    if not body:
        return None, ("The reply was empty.",)
    fenced = _FENCE.match(body)
    if fenced:
        body = fenced.group("body").strip()
    try:
        data = json.loads(body)
    except json.JSONDecodeError:
        return None, ("The reply was not a single JSON object.",)
    if not isinstance(data, dict):
        return None, ("The reply was JSON but not an object.",)
    return data, ()


def run_attempts(
    model: VisionModel,
    build_instructions: Callable[[tuple[str, ...]], str],
    user_text: str,
    image_webp: bytes,
    check: Callable[[dict[str, Any]], tuple[T | None, CheckReport]],
    attempts: int = MAX_ATTEMPTS,
    extra_images: Sequence[bytes] = (),
) -> AttemptsOutcome[T]:
    """Asks the model up to `attempts` times and keeps the first reply that passes."""
    records: list[Attempt] = []
    previous: tuple[str, ...] = ()
    for _ in range(attempts):
        started = time.monotonic()
        try:
            instructions = build_instructions(previous)
            if extra_images:
                reply = model.respond(instructions, user_text, image_webp, extra_images)
            else:
                reply = model.respond(instructions, user_text, image_webp)
        except ModelError:
            records.append(
                Attempt(
                    raw_text="",
                    report=failed("The model request failed."),
                    model=None,
                    latency_ms=int((time.monotonic() - started) * 1000),
                )
            )
            continue
        latency_ms = int((time.monotonic() - started) * 1000)

        result = None
        if reply.refusal:
            report = failed("The model declined the request.")
        else:
            data, parse_issues = parse_raw(reply.text)
            if data is None:
                report = failed(*parse_issues)
            else:
                result, report = check(data)

        records.append(
            Attempt(
                raw_text=reply.text[:MAX_RAW_CHARS],
                report=report,
                model=reply.model,
                latency_ms=latency_ms,
                input_tokens=reply.input_tokens,
                output_tokens=reply.output_tokens,
            )
        )
        if result is not None:
            return AttemptsOutcome(attempts=records, result=result)
        previous = report.issues
    return AttemptsOutcome(attempts=records)
