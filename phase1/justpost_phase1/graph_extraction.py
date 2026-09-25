from __future__ import annotations

import json
from pathlib import Path

from google import genai
from google.genai import types
from PIL import Image
from pydantic import BaseModel, Field

from .models import ExtractedElement, FormatSpec, SlideshowAnalysis
from .policy import apply_permissions

ANALYZE_PROMPT = """You are analyzing a TikTok slideshow / carousel for an affiliate variation engine.

You will be given every slide in upload order, plus any on-device OCR text.
Return one JSON object with TWO layers.

LAYER 1 — format (the whole slideshow, this job only):
- hook_mechanic: curiosity_gap | relatable_moment | stated_benefit | or a short label
- slide_count: integer, must match the number of images you were given
- pacing: sequential_reveal | fast_montage | or a short label
- information_order: e.g. tease_then_stepbystep_then_payoff
- payoff_style: aesthetic_result | social_proof | emotional_close | or a short label

LAYER 2 — slides[] in the same order as the images (slide_index 0-based):
Each slide has elements[] — every distinct visual region.

type (exactly one):
- text: captions, prices, CTAs, stickers with words
- arrow: arrows, carets, drawn pointers
- subject: a person or identifiable body
- background: real scenery or the photo *inside* a device preview. NOT editor canvas.
- ui_element: real app/OS UI AND host editor chrome (black/gray canvas, bezels,
  status bars, Focus, Customize, page dots, sheets). Apple/Google chrome is
  ui_element, even a large flat black field.
- overlay_graphic: creator graphics without words (hearts, frames, face covers)
- emoji: standalone emoji

role (exactly one — this is the lock tag, not a restatement of type):
- protected: never eligible for any edit (real system UI, proof screenshots)
- preserve_identity: subject; scoped edits only on editable_attributes
- editable: backgrounds/scenery that may vary
- creator_signature: the creator's own overlay (e.g. face-cover). Position/anchor
  locked; restylable later in composite, not by an image model.

Relationships:
- points_to: element id an arrow points at (arrows only, else omit)
- anchors_to: element id an overlay is locked to (overlay_graphic / emoji)

For type=subject:
- editable_attributes: e.g. ["garment_color"]
- locked_attributes: e.g. ["pose", "silhouette", "face_visibility"]
  An edit may only ever target editable_attributes.

For type=text, copy visible words into text (prefer OCR if provided).

Tutorial / app-screenshot: ui_element on device chrome and the canvas around a
preview is protected. The picture *inside* the phone is background / editable.

Bounding boxes are fractional 0–1 of that slide: x, y, w, h (x,y = top-left).
Approximate is OK — VLMs localize text better than arrows/icons. Prefer tight
boxes. Do not invent elements. Stable ids like e1, e2 per slide. confidence 0–1.
"""


class _ExtractedSlide(BaseModel):
    slide_index: int = 0
    elements: list[ExtractedElement] = Field(default_factory=list)


class _AnalysisPayload(BaseModel):
    hook_mechanic: str = ""
    slide_count: int = 0
    pacing: str = ""
    information_order: str = ""
    payoff_style: str = ""
    slides: list[_ExtractedSlide] = Field(default_factory=list)


def analyze_slideshow(
    client: genai.Client,
    image_paths: list[Path],
    ocr_texts: list[str] | None = None,
    model: str = "gemini-3.6-flash",
) -> SlideshowAnalysis:
    if not image_paths:
        raise ValueError("analyze_slideshow requires at least one image")
    ocr_texts = ocr_texts or [""] * len(image_paths)
    if len(ocr_texts) != len(image_paths):
        raise ValueError("ocr_texts must match image_paths length")

    images = [Image.open(path).convert("RGB") for path in image_paths]
    ocr_block = "\n".join(
        f"Slide {index} ({path.name}) OCR: {text.strip() or '(none supplied)'}"
        for index, (path, text) in enumerate(zip(image_paths, ocr_texts))
    )
    prompt = (
        f"{ANALYZE_PROMPT}\n\n"
        f"You were given {len(image_paths)} slide image(s) in order.\n"
        f"{ocr_block}"
    )
    response = client.models.generate_content(
        model=model,
        contents=[prompt, *images],
        config=types.GenerateContentConfig(
            response_mime_type="application/json",
            response_schema=_AnalysisPayload,
            temperature=0.2,
        ),
    )
    payload = _AnalysisPayload.model_validate(json.loads(response.text))
    format_spec = FormatSpec(
        hook_mechanic=payload.hook_mechanic,
        slide_count=len(image_paths),
        pacing=payload.pacing,
        information_order=payload.information_order,
        payoff_style=payload.payoff_style,
    )
    by_index = {item.slide_index: item for item in payload.slides}
    slides = []
    for index, (path, image, ocr) in enumerate(zip(image_paths, images, ocr_texts)):
        extracted = by_index[index].elements if index in by_index else []
        slides.append(
            apply_permissions(
                slide_id=path.stem,
                source_path=str(path),
                width_px=image.size[0],
                height_px=image.size[1],
                extracted=extracted,
                format_spec=format_spec,
                ocr_text=ocr,
            )
        )
    return SlideshowAnalysis(format=format_spec, slides=slides)
