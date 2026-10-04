"""Validated analysis and execution models for the image-variation pipeline."""

from __future__ import annotations

from enum import StrEnum

from pydantic import BaseModel, Field, model_validator


class ElementType(StrEnum):
    TEXT = "text"
    ARROW = "arrow"
    SUBJECT = "subject"
    BACKGROUND = "background"
    UI_ELEMENT = "ui_element"
    OVERLAY_GRAPHIC = "overlay_graphic"
    EMOJI = "emoji"


class EditRole(StrEnum):
    PROTECTED = "protected"
    PRESERVE_IDENTITY = "preserve_identity"
    EDITABLE = "editable"
    CREATOR_SIGNATURE = "creator_signature"


# Never dispatched to an image-edit model. Client-composited later.
NEVER_IMAGE_EDIT_TYPES: frozenset[ElementType] = frozenset(
    {
        ElementType.TEXT,
        ElementType.ARROW,
        ElementType.EMOJI,
        ElementType.OVERLAY_GRAPHIC,
    }
)

class BBox(BaseModel):
    """Axis-aligned box in fractional 0–1 coordinates (left, top, width, height)."""

    x: float = Field(ge=0.0, le=1.0)
    y: float = Field(ge=0.0, le=1.0)
    # ge=0 (not gt=0): Gemini's response_schema rejects exclusiveMinimum.
    w: float = Field(ge=0.0, le=1.0)
    h: float = Field(ge=0.0, le=1.0)

    @model_validator(mode="after")
    def _fits_canvas(self) -> BBox:
        if self.w <= 0 or self.h <= 0:
            raise ValueError(f"bbox has empty size: {self}")
        if self.x + self.w > 1.0 + 1e-6 or self.y + self.h > 1.0 + 1e-6:
            raise ValueError(f"bbox exceeds 0–1 canvas: {self}")
        return self

    def clamp(self) -> BBox:
        w = min(self.w, 1.0 - self.x)
        h = min(self.h, 1.0 - self.y)
        return BBox(x=self.x, y=self.y, w=max(w, 1e-4), h=max(h, 1e-4))

    def overlaps(self, other: BBox) -> bool:
        return not (
            self.x + self.w <= other.x
            or other.x + other.w <= self.x
            or self.y + self.h <= other.y
            or other.y + other.h <= self.y
        )

    def pixel_rect(self, width: int, height: int) -> tuple[int, int, int, int]:
        left = int(round(self.x * width))
        top = int(round(self.y * height))
        right = int(round((self.x + self.w) * width))
        bottom = int(round((self.y + self.h) * height))
        return (
            max(0, min(left, width - 1)),
            max(0, min(top, height - 1)),
            max(left + 1, min(right, width)),
            max(top + 1, min(bottom, height)),
        )


class Permissions(BaseModel):
    editable: bool
    lock_reason: str | None = None


class FormatSpec(BaseModel):
    """Layer 1 — job-scoped creative brief. Not a reusable v1 object."""

    hook_mechanic: str = ""
    slide_count: int = 0
    pacing: str = ""
    information_order: str = ""
    payoff_style: str = ""


class ExtractedElement(BaseModel):
    """Raw model proposal — permissions are applied in code after extraction."""

    id: str
    type: ElementType
    role: EditRole
    bbox: BBox
    label: str = ""
    text: str = ""
    points_to: str | None = None
    anchors_to: str | None = None
    editable_attributes: list[str] = Field(default_factory=list)
    locked_attributes: list[str] = Field(default_factory=list)
    confidence: float | None = None


class Element(BaseModel):
    id: str
    type: ElementType
    role: EditRole
    bbox: BBox
    label: str = ""
    text: str = ""
    points_to: str | None = None
    anchors_to: str | None = None
    editable_attributes: list[str] = Field(default_factory=list)
    locked_attributes: list[str] = Field(default_factory=list)
    permissions: Permissions
    confidence: float | None = None


class SlideGraph(BaseModel):
    slide_id: str
    source_path: str
    width_px: int
    height_px: int
    ocr_text: str = ""
    format: FormatSpec | None = None
    elements: list[Element] = Field(default_factory=list)

    def locked_elements(self) -> list[Element]:
        return [e for e in self.elements if not e.permissions.editable]

    def editable_elements(self) -> list[Element]:
        return [e for e in self.elements if e.permissions.editable]


class SlideshowAnalysis(BaseModel):
    format: FormatSpec
    slides: list[SlideGraph] = Field(default_factory=list)


class ProposedEdit(BaseModel):
    element_id: str
    instruction: str
    target_attributes: list[str] = Field(default_factory=list)


class FilteredEdit(BaseModel):
    proposal: ProposedEdit
    allowed: bool
    reason: str
    element: Element | None = None


class VerificationScore(BaseModel):
    element_id: str
    role: EditRole
    mean_abs: float
    max_abs: float
    ssim: float
    passed: bool
    used_ink_mask: bool = False
    compared_pixels: int = 0


class VerificationResult(BaseModel):
    passed: bool
    scores: list[VerificationScore]
    mean_abs_threshold: float
    ssim_threshold: float
    fallback_to_original: bool
