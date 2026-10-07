"""Phase 6: draw a plan's slide text onto its generated image, in code.

No model is involved: the text is the checked plan text, and every size is a
fraction of the canvas, so the same layout gives the same composition at any
resolution. Pillow's basic layout engine is used everywhere so the server and
local tests draw identically.
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass, field
from functools import lru_cache
from io import BytesIO
from pathlib import Path
from typing import Any

from fontTools.ttLib import TTFont
from PIL import Image, ImageDraw, ImageFont

from justpost.generation import clean_png
from justpost.layout_schema import SCHEMA_VERSION, Layout, LayoutChoice, Style
from justpost.model_io import CheckReport, failed

FONTS_DIR = Path(__file__).parent / "fonts"
FONT_FILES: dict[str, str] = {
    "outlined": "Inter-ExtraBold.ttf",
    "white_box": "Inter-Bold.ttf",
    "dark_box": "Inter-Bold.ttf",
}

# Font size limits, as fractions of the canvas height.
MIN_FONT = 0.025
MAX_FONT = 0.06
MAX_LINES = 6
LINE_HEIGHT = 1.2
# These are fractions of the font size.
STROKE = 0.08
PADDING = 0.35
RADIUS = 0.3

# A reference text box is often tight around the original words; new text
# needs room to wrap.
MIN_REFERENCE_W = 0.6
MIN_REFERENCE_H = 0.18
PRESETS: dict[str, dict[str, float]] = {
    "top": {"x": 0.08, "y": 0.08, "w": 0.84, "h": 0.2},
    "middle": {"x": 0.08, "y": 0.4, "w": 0.84, "h": 0.2},
    # Ends at 82% so TikTok's caption and buttons don't cover it.
    "bottom": {"x": 0.08, "y": 0.62, "w": 0.84, "h": 0.2},
}
FALLBACK_ORDER = ("reference", "bottom", "top", "middle")
# Keep-clear boxes from the check are approximate, so a sliver of overlap is allowed.
MAX_OVERLAP = 0.1

WHITE = (255, 255, 255, 255)
INK = (20, 18, 24, 255)
BLACK = (0, 0, 0, 255)
DARK_BOX = (0, 0, 0, 170)


@lru_cache(maxsize=1)
def _codepoints() -> frozenset[int]:
    fonts = {FONT_FILES[style] for style in FONT_FILES}
    sets = [set(TTFont(FONTS_DIR / name).getBestCmap()) for name in fonts]
    return frozenset(set.intersection(*sets))


def missing_characters(text: str) -> list[str]:
    """Characters the bundled fonts have no glyph for, in order of appearance."""
    missing: list[str] = []
    for char in text:
        if ord(char) not in _codepoints() and char not in missing:
            missing.append(char)
    return missing


@lru_cache(maxsize=256)
def _font(style: Style, size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(
        FONTS_DIR / FONT_FILES[style], size, layout_engine=ImageFont.Layout.BASIC
    )


def _grow(region: dict[str, float]) -> dict[str, float]:
    """Widens and heightens a box around its center, keeping it inside the frame."""

    def span(start: float, length: float, minimum: float) -> tuple[float, float]:
        size = min(1.0, max(length, minimum))
        center = start + length / 2
        return min(max(center - size / 2, 0.0), 1.0 - size), size

    x, w = span(region["x"], region["w"], MIN_REFERENCE_W)
    y, h = span(region["y"], region["h"], MIN_REFERENCE_H)
    return {key: round(value, 4) for key, value in {"x": x, "y": y, "w": w, "h": h}.items()}


def box_for(position: str, analysis: dict[str, Any], copy_role: str) -> dict[str, float]:
    if position != "reference":
        return dict(PRESETS[position])
    blocks = [block for block in analysis.get("copy") or [] if isinstance(block, dict)]
    block = next((b for b in blocks if b.get("role") == copy_role), blocks[0] if blocks else None)
    if block is None:
        return dict(PRESETS["bottom"])
    return _grow(block["region"])


def layout_for(choice: LayoutChoice, analysis: dict[str, Any], copy_role: str) -> Layout:
    return Layout.model_validate(
        {
            "schemaVersion": SCHEMA_VERSION,
            "style": choice.style,
            "position": choice.position,
            "align": choice.align,
            "box": box_for(choice.position, analysis, copy_role),
        }
    )


def wrap(text: str, font: ImageFont.FreeTypeFont, max_width: float) -> list[str] | None:
    """Greedy word wrap; None when a single word is wider than the line."""
    lines: list[str] = []
    current = ""
    for word in text.split():
        candidate = f"{current} {word}" if current else word
        if font.getlength(candidate) <= max_width:
            current = candidate
        elif font.getlength(word) > max_width:
            return None
        else:
            lines.append(current)
            current = word
    if current:
        lines.append(current)
    return lines


@dataclass(frozen=True)
class Fit:
    size: int
    lines: list[str]
    stroke: int
    padding: int

    @property
    def inset(self) -> int:
        return self.stroke + self.padding


def fit_text(text: str, style: Style, box_px: tuple[int, int], canvas_height: int) -> Fit | None:
    """The largest font size whose wrapped text fits inside the box."""
    box_w, box_h = box_px
    largest = max(1, round(MAX_FONT * canvas_height))
    smallest = max(1, round(MIN_FONT * canvas_height))
    for size in range(largest, smallest - 1, -1):
        stroke = max(1, round(STROKE * size)) if style == "outlined" else 0
        padding = round(PADDING * size) if style != "outlined" else 0
        inset = stroke + padding
        lines = wrap(text, _font(style, size), box_w - 2 * inset)
        if not lines or len(lines) > MAX_LINES:
            continue
        if len(lines) * round(LINE_HEIGHT * size) > box_h - 2 * inset:
            continue
        return Fit(size=size, lines=lines, stroke=stroke, padding=padding)
    return None


def _box_px(layout: Layout, width: int, height: int) -> tuple[int, int, int, int]:
    box = layout.box
    return (
        round(box.x * width),
        round(box.y * height),
        round(box.w * width),
        round(box.h * height),
    )


@dataclass(frozen=True)
class _Block:
    """Where the wrapped text sits, in pixels."""

    left: float
    top: float
    width: float
    height: float
    line_height: int


def _block(layout: Layout, fit: Fit, width: int, height: int) -> _Block:
    box_x, box_y, box_w, box_h = _box_px(layout, width, height)
    font = _font(layout.style, fit.size)
    line_height = round(LINE_HEIGHT * fit.size)
    block_w = max(font.getlength(line) for line in fit.lines)
    block_h = len(fit.lines) * line_height
    top = box_y + (box_h - block_h) / 2
    left = box_x + (box_w - block_w) / 2 if layout.align == "center" else box_x + fit.inset
    return _Block(left, top, block_w, block_h, line_height)


def text_region(layout: Layout, fit: Fit, width: int, height: int) -> dict[str, float]:
    """Everything the text covers, box or outline included, as canvas fractions."""
    block = _block(layout, fit, width, height)
    inset = fit.inset
    left = max(0.0, block.left - inset)
    top = max(0.0, block.top - inset)
    right = min(float(width), block.left + block.width + inset)
    bottom = min(float(height), block.top + block.height + inset)
    return {
        "x": round(left / width, 4),
        "y": round(top / height, 4),
        "w": round((right - left) / width, 4),
        "h": round((bottom - top) / height, 4),
    }


def covered_area(text: dict[str, float], keep_clear: Sequence[dict[str, Any]]) -> str | None:
    """The label of the first keep-clear area the text covers too much of."""
    for area in keep_clear:
        region = area["region"]
        overlap_w = min(text["x"] + text["w"], region["x"] + region["w"]) - max(text["x"], region["x"])
        overlap_h = min(text["y"] + text["h"], region["y"] + region["h"]) - max(text["y"], region["y"])
        area_size = region["w"] * region["h"]
        if overlap_w > 0 and overlap_h > 0 and area_size > 0:
            if overlap_w * overlap_h / area_size > MAX_OVERLAP:
                return str(area["label"])
    return None


def draw(image: Image.Image, layout: Layout, fit: Fit) -> Image.Image:
    width, height = image.size
    box_x, _, box_w, _ = _box_px(layout, width, height)
    font = _font(layout.style, fit.size)
    block = _block(layout, fit, width, height)
    left, top, line_height = block.left, block.top, block.line_height

    overlay = Image.new("RGBA", image.size, (0, 0, 0, 0))
    pen = ImageDraw.Draw(overlay)
    if layout.style != "outlined":
        pen.rounded_rectangle(
            (
                left - fit.padding,
                top - fit.padding,
                left + block.width + fit.padding,
                top + block.height + fit.padding,
            ),
            radius=round(RADIUS * fit.size),
            fill=WHITE if layout.style == "white_box" else DARK_BOX,
        )
    fill = INK if layout.style == "white_box" else WHITE
    for index, line in enumerate(fit.lines):
        y = top + index * line_height + line_height / 2
        if layout.align == "center":
            x, anchor = box_x + box_w / 2, "mm"
        else:
            x, anchor = left, "lm"
        pen.text(
            (x, y),
            line,
            font=font,
            fill=fill,
            anchor=anchor,
            stroke_width=fit.stroke,
            stroke_fill=BLACK,
        )
    return Image.alpha_composite(image.convert("RGBA"), overlay).convert("RGB")


@dataclass(frozen=True)
class RenderOutcome:
    layout: dict[str, Any]
    report: CheckReport
    width: int
    height: int
    png: bytes | None = None
    font_size_px: int | None = None
    lines: list[str] = field(default_factory=list)
    text_region: dict[str, float] | None = None

    @property
    def passed(self) -> bool:
        return self.png is not None


def render_slide(
    image_png: bytes,
    text: str | None,
    choice: LayoutChoice,
    analysis: dict[str, Any],
    copy_role: str,
    keep_clear: Sequence[dict[str, Any]] = (),
    find_clear_position: bool = False,
) -> RenderOutcome:
    """Draws `text` on the image, away from the keep-clear areas. A plan without
    text gives the image unchanged.

    With `find_clear_position`, a position where the text doesn't fit or would
    cover a keep-clear area is swapped for the next one in `FALLBACK_ORDER`;
    otherwise the chosen position is used or the render fails.
    """
    image = Image.open(BytesIO(image_png))
    image.load()
    rgb = image.convert("RGB")
    width, height = rgb.size
    chosen = layout_for(choice, analysis, copy_role)

    def failure(issue: str) -> RenderOutcome:
        return RenderOutcome(chosen.model_dump(), failed(issue), width, height)

    if text is None:
        return RenderOutcome(
            chosen.model_dump(), CheckReport(passed=True), width, height, clean_png(rgb)
        )

    missing = missing_characters(text)
    if missing:
        return failure("The font can't draw these characters: " + " ".join(missing))

    positions = [choice.position]
    if find_clear_position:
        positions += [p for p in FALLBACK_ORDER if p != choice.position]

    first_issue: str | None = None
    for position in positions:
        layout = layout_for(choice.model_copy(update={"position": position}), analysis, copy_role)
        _, _, box_w, box_h = _box_px(layout, width, height)
        fit = fit_text(text, layout.style, (box_w, box_h), height)
        if fit is None:
            issue = "The text doesn't fit in this position. Try another position."
        else:
            region = text_region(layout, fit, width, height)
            label = covered_area(region, keep_clear)
            if label is None:
                return RenderOutcome(
                    layout=layout.model_dump(),
                    report=CheckReport(passed=True),
                    width=width,
                    height=height,
                    png=clean_png(draw(rgb, layout, fit)),
                    font_size_px=fit.size,
                    lines=fit.lines,
                    text_region=region,
                )
            issue = f"The text would cover the {label}. Try another position."
        first_issue = first_issue or issue

    if len(positions) > 1:
        return failure("No position keeps the text clear of the image's subject.")
    return failure(first_issue or "The text couldn't be placed.")
