"""Phase 4: the structure a set of variation plans must have before JustPost saves it.

The same models check AI drafts and user edits; count limits differ by source
and are enforced in planning.py.
"""

from __future__ import annotations

from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, StringConstraints

from justpost.blueprint_schema import ItemId, Label, Origin, RunId

SCHEMA_VERSION = 1
MIN_PLANS = 1
MAX_PLANS = 5
MAX_HOOK_CHARS = 150

Value = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=120)]
HookText = Annotated[
    str, StringConstraints(strip_whitespace=True, min_length=1, max_length=MAX_HOOK_CHARS)
]


class _Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


class Change(_Strict):
    dimensionId: ItemId
    value: Value


class PlanCopy(_Strict):
    text: HookText
    pattern: Label


class VariationPlan(_Strict):
    id: ItemId
    origin: Origin
    title: Label
    changes: list[Change] = Field(max_length=12)
    # Aliased because `copy` is a BaseModel method; dump with by_alias=True.
    plan_copy: PlanCopy | None = Field(alias="copy")


class PlanSet(_Strict):
    schemaVersion: Literal[1]
    analysisRunId: RunId
    blueprintVersion: int = Field(ge=1)
    plans: list[VariationPlan] = Field(max_length=MAX_PLANS)


# Changes per plan for AI drafts: medium variation strength, never everything.
AI_MIN_CHANGES = 2
AI_MAX_CHANGES = 4
