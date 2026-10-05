"""Phase 2: the structure a creative analysis must have before JustPost uses it.

Field names match the JSON the model is asked to return, so a model answer can
be validated directly.
"""

from __future__ import annotations

from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, model_validator

SCHEMA_VERSION = 1
# Rounding slack so a box that ends exactly on the frame edge isn't rejected.
EDGE_TOLERANCE = 0.005

Short = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=200)]
Label = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=60)]
SlideText = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=500)]
Fraction = Annotated[float, Field(ge=0.0, le=1.0)]


class _Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


class Region(_Strict):
    """A box in fractions of the slide's width and height, from the top-left."""

    x: Fraction
    y: Fraction
    w: Fraction
    h: Fraction

    @model_validator(mode="after")
    def _inside_frame(self) -> Region:
        if self.w <= 0 or self.h <= 0:
            raise ValueError("region must have a positive width and height")
        if self.x + self.w > 1 + EDGE_TOLERANCE or self.y + self.h > 1 + EDGE_TOLERANCE:
            raise ValueError("region extends outside the slide")
        return self


class Scene(_Strict):
    environment: Short
    lighting: Short
    background: Short
    cameraStyle: Short


class Subject(_Strict):
    description: Short
    position: Short
    styling: list[Short] = Field(max_length=10)
    faceVisibility: Literal["visible", "partial", "obscured", "not_shown"]
    holding: Short | None = None
    region: Region | None = None


class VisualDevice(_Strict):
    type: Label
    description: Short
    role: Short
    region: Region | None = None


class CopyBlock(_Strict):
    text: SlideText
    role: Literal["hook", "supporting", "call_to_action", "caption", "label", "other"]
    region: Region


class Composition(_Strict):
    orientation: Literal["portrait", "landscape", "square"]
    subjectWeight: Short
    textPlacement: Short
    visualHierarchy: list[Short] = Field(min_length=1, max_length=8)


class CreativeAnalysis(_Strict):
    schemaVersion: Literal[1]
    creativeType: Label
    scene: Scene
    subjects: list[Subject] = Field(max_length=10)
    visualDevices: list[VisualDevice] = Field(max_length=10)
    # Aliased because `copy` is a BaseModel method; dump with by_alias=True.
    slide_copy: list[CopyBlock] = Field(alias="copy", max_length=12)
    hookType: Label | None
    mechanisms: list[Short] = Field(max_length=10)
    composition: Composition
    aesthetic: list[Label] = Field(min_length=1, max_length=10)
    centralElements: list[Short] = Field(min_length=1, max_length=10)
