"""Phase 5: make one new image per confirmed plan, then check it in code.

Code, not a model, writes the image request from the confirmed blueprint and
the plan. The checks here only cover what code can verify about the file
itself; whether the image follows the blueprint is judged afterwards by
`validation.py`.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from io import BytesIO
from typing import Any

from PIL import Image, ImageStat, UnidentifiedImageError

from justpost.ingest import MAX_PIXELS
from justpost.model_io import CheckReport, ImageModel, ModelError, ModelRefusal, failed

LONG_SIDE = 1536
SIZE_STEP = 16
MIN_ASPECT = 1 / 3
MAX_ASPECT = 3.0
# Grayscale standard deviation; all-black or single-color images fall below it.
MIN_PIXEL_SPREAD = 4.0

_OPENING = (
    "Use the reference image for style, camera angle, lighting and realism. "
    "Make a new image; don't copy it pixel for pixel."
)
_NO_TEXT = (
    "No text, captions, lettering or logos anywhere in the image. Where the "
    "reference has text, continue the scene instead."
)


def output_size(width: int, height: int) -> tuple[int, int]:
    """The slide's shape with its longest side at 1536 px, in steps of 16 px."""
    aspect = min(max(width / height, MIN_ASPECT), MAX_ASPECT)

    def step(value: float) -> int:
        return max(SIZE_STEP, round(value / SIZE_STEP) * SIZE_STEP)

    if aspect <= 1:
        return step(LONG_SIDE * aspect), LONG_SIDE
    return LONG_SIDE, step(LONG_SIDE / aspect)


def size_text(size: tuple[int, int]) -> str:
    return f"{size[0]}x{size[1]}"


def plans_are_stale(plans: dict[str, Any], blueprint_version: int, analysis_run_id: str) -> bool:
    return (
        plans.get("blueprintVersion") != blueprint_version
        or plans.get("analysisRunId") != analysis_run_id
    )


def find_plan(plans: dict[str, Any], plan_id: str) -> dict[str, Any] | None:
    for plan in plans.get("plans") or []:
        if isinstance(plan, dict) and plan.get("id") == plan_id:
            return plan
    return None


def build_request(blueprint: dict[str, Any], plan: dict[str, Any]) -> str:
    """The image request, from checked data only. The plan's slide text is left
    out on purpose: Phase 6 draws it."""
    names = {
        item["id"]: item["name"] for item in blueprint.get("variationDimensions") or []
    }

    def bullets(lines: list[str]) -> str:
        return "\n".join(f"- {line}" for line in lines)

    keep = [item["text"] for item in blueprint.get("requiredPrinciples") or []]
    keep += [
        f"{item['text']} (preferred)" for item in blueprint.get("preferredPrinciples") or []
    ]
    changes = [
        f"{names.get(change['dimensionId'], change['dimensionId'])}: {change['value']}"
        for change in plan.get("changes") or []
    ]
    never = [item["text"] for item in blueprint.get("forbiddenDrift") or []]

    parts = [_OPENING]
    if keep:
        parts.append("Keep:\n" + bullets(keep))
    if changes:
        parts.append("For this variation:\n" + bullets(changes))
    if never:
        parts.append("Never:\n" + bullets(never))
    parts.append(_NO_TEXT)
    return "\n\n".join(parts)


def check_image(data: bytes, size: tuple[int, int]) -> tuple[bytes | None, CheckReport]:
    """Returns the image re-saved as PNG without metadata, if it passes."""
    try:
        image = Image.open(BytesIO(data))
        if image.format != "PNG":
            return None, failed(f"The image is {image.format}, not PNG.")
        width, height = image.size
        if width * height > MAX_PIXELS:
            return None, failed("The image is too large.")
        image.load()
    except (UnidentifiedImageError, Image.DecompressionBombError, OSError):
        return None, failed("The reply was not a readable image.")

    if image.size != size:
        return None, failed(
            f"The image is {width}x{height}, not the requested {size_text(size)}."
        )

    if image.mode in {"RGBA", "LA", "PA"} or "transparency" in image.info:
        rgba = image.convert("RGBA")
        rgb = Image.new("RGB", rgba.size, "white")
        rgb.paste(rgba, mask=rgba.getchannel("A"))
    else:
        rgb = image.convert("RGB")
    if ImageStat.Stat(rgb.convert("L")).stddev[0] < MIN_PIXEL_SPREAD:
        return None, failed("The image is blank or a single color.")
    return clean_png(rgb), CheckReport(passed=True)


def clean_png(rgb: Image.Image) -> bytes:
    """Rebuilt from pixels alone, so no EXIF, text chunks or color profile survive."""
    clean = Image.frombytes("RGB", rgb.size, rgb.tobytes())
    buffer = BytesIO()
    clean.save(buffer, "PNG", compress_level=6)
    return buffer.getvalue()


@dataclass(frozen=True)
class GenerationOutcome:
    report: CheckReport
    latency_ms: int
    png: bytes | None = None
    model: str | None = None
    input_tokens: int | None = None
    output_tokens: int | None = None

    @property
    def passed(self) -> bool:
        return self.png is not None


def generate(
    request: str, reference_webp: bytes, size: tuple[int, int], model: ImageModel
) -> GenerationOutcome:
    """Makes one image request, without retrying, and checks the result."""
    started = time.monotonic()

    def elapsed() -> int:
        return int((time.monotonic() - started) * 1000)

    try:
        reply = model.edit(request, reference_webp, size_text(size))
    except ModelRefusal:
        return GenerationOutcome(failed("The image model declined this plan."), elapsed())
    except ModelError:
        return GenerationOutcome(failed("The image request failed."), elapsed())

    png, report = check_image(reply.image, size)
    return GenerationOutcome(
        report=report,
        latency_ms=elapsed(),
        png=png,
        model=reply.model,
        input_tokens=reply.input_tokens,
        output_tokens=reply.output_tokens,
    )
