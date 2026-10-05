"""Phase 3: the structure a creative blueprint must have before JustPost saves it.

The same models check AI drafts and user edits; minimum list sizes differ by
source and are enforced in blueprint.py.
"""

from __future__ import annotations

from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, StringConstraints

SCHEMA_VERSION = 1

ItemId = Annotated[str, StringConstraints(pattern=r"^[a-z0-9_-]{1,40}$")]
RunId = Annotated[str, StringConstraints(pattern=r"^[A-Za-z0-9_-]{1,40}$")]
BasisPath = Annotated[str, StringConstraints(pattern=r"^[A-Za-z0-9_.]{1,80}$")]
Short = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=200)]
Label = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=80)]
Origin = Literal["ai", "user"]
CopyRole = Literal["hook", "supporting", "call_to_action", "caption", "label", "other", "none"]


class _Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


class Principle(_Strict):
    id: ItemId
    text: Short
    basis: list[BasisPath] = Field(max_length=6)
    origin: Origin


class VariationDimension(_Strict):
    id: ItemId
    name: Label
    examples: list[Label] = Field(max_length=5)
    basis: list[BasisPath] = Field(max_length=6)
    origin: Origin


class CopyStrategy(_Strict):
    role: CopyRole
    primaryPattern: Short
    secondaryPattern: Short | None = None


class Blueprint(_Strict):
    schemaVersion: Literal[1]
    analysisRunId: RunId
    creativeFamily: Label
    objective: Short
    requiredPrinciples: list[Principle] = Field(max_length=10)
    preferredPrinciples: list[Principle] = Field(max_length=8)
    variationDimensions: list[VariationDimension] = Field(max_length=12)
    forbiddenDrift: list[Principle] = Field(max_length=8)
    copyStrategy: CopyStrategy


# Minimum items per section: AI drafts must be substantive; user edits may trim.
MIN_ITEMS = {
    "ai": {
        "requiredPrinciples": 3,
        "preferredPrinciples": 0,
        "variationDimensions": 3,
        "forbiddenDrift": 2,
    },
    "user": {
        "requiredPrinciples": 1,
        "preferredPrinciples": 0,
        "variationDimensions": 1,
        "forbiddenDrift": 0,
    },
}
SECTIONS = tuple(MIN_ITEMS["ai"])
