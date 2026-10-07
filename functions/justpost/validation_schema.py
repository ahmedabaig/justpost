"""Phase 7: the structure an image check reply must have before JustPost uses it."""

from __future__ import annotations

from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, StringConstraints

from justpost.analysis_schema import Region

SCHEMA_VERSION = 1
MAX_KEEP_CLEAR = 6

Answer = Literal["yes", "no", "unsure"]
CheckId = Annotated[str, StringConstraints(min_length=1, max_length=60)]
Note = Annotated[str, StringConstraints(strip_whitespace=True, max_length=200)]
Label = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=40)]


class _Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


class CheckAnswer(_Strict):
    id: CheckId
    answer: Answer
    note: Note = ""


class KeepClear(_Strict):
    label: Label
    region: Region


class CheckReply(_Strict):
    schemaVersion: Literal[1]
    checks: list[CheckAnswer] = Field(max_length=60)
    keepClear: list[KeepClear] = Field(max_length=MAX_KEEP_CLEAR)
