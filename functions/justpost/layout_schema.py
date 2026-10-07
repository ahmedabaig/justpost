"""Phase 6: how the slide text is laid out, in fractions of the canvas.

The app only chooses a style, a position and an alignment; the box is always
worked out by the server, so the app can't place text outside the frame or
send sizes in pixels.
"""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict

from justpost.analysis_schema import Region

SCHEMA_VERSION = 1

Style = Literal["outlined", "white_box", "dark_box"]
Position = Literal["reference", "top", "middle", "bottom"]
Align = Literal["center", "left"]


class _Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


class LayoutChoice(_Strict):
    """What the app may send."""

    style: Style = "outlined"
    position: Position = "reference"
    align: Align = "center"


class Layout(_Strict):
    """What a slide is drawn from and stored with."""

    schemaVersion: Literal[1]
    style: Style
    position: Position
    align: Align
    box: Region
