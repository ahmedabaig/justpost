from __future__ import annotations

import base64
import os
from dataclasses import dataclass
from io import BytesIO
from pathlib import Path

from openai import OpenAI
from PIL import Image

from .models import (
    EditRole,
    ElementType,
    FilteredEdit,
    FormatSpec,
    ProposedEdit,
    SlideGraph,
    SlideshowAnalysis,
)

DEFAULT_IMAGE_MODEL = "gpt-image-2.5-flare"


@dataclass
class ScopedEditResult:
    image: Image.Image
    skipped: bool = False
    skip_reason: str | None = None
    prompt: str | None = None


def openai_size_label(width: int, height: int) -> str:
    ratio = width / height
    if abs(ratio - 1.0) < 0.12:
        return "1024x1024"
    if width > height:
        return "1536x1024"
    return "1024x1536"


def _image_from_edit_response(response) -> Image.Image:
    data = response.data
    if not data:
        raise RuntimeError(f"OpenAI returned no image: {response}")
    first = data[0]
    raw = getattr(first, "b64_json", None)
    if not raw:
        raise RuntimeError(f"OpenAI returned no b64 image: {response}")
    return Image.open(BytesIO(base64.b64decode(raw))).convert("RGB")


def _keep_lines(graph: SlideGraph, allowed_ids: set[str]) -> list[str]:
    lines = []
    for element in graph.elements:
        if element.id in allowed_ids:
            continue
        label = element.label or element.type.value.replace("_", " ")
        if element.text:
            lines.append(
                f'- Keep the {label}, including the exact text "{element.text}", '
                "font style, text bubble, size, and placement. Show it exactly once."
            )
        elif element.type == ElementType.UI_ELEMENT:
            lines.append(
                f"- Keep the {label} and all of its interface controls unchanged."
            )
        elif element.type in {
            ElementType.ARROW,
            ElementType.EMOJI,
            ElementType.OVERLAY_GRAPHIC,
        }:
            lines.append(
                f"- Keep the {label} exactly the same in appearance and placement."
            )
        else:
            lines.append(f"- Keep the {label} unchanged.")
    return lines


def _change_lines(allowed: list[FilteredEdit]) -> list[str]:
    lines = []
    for item in allowed:
        element = item.element
        if element is None:
            continue
        label = element.label or element.type.value.replace("_", " ")
        lines.append(
            f"- Change the {label}: {item.proposal.instruction}"
        )
    return lines


def build_variation_prompt(
    graph: SlideGraph,
    allowed: list[FilteredEdit],
    analysis: SlideshowAnalysis | None = None,
) -> str:
    """Concise painter prompt distilled from analysis and the filtered graph."""
    fmt = FormatSpec()
    slide_number = 1
    if analysis is not None:
        fmt = analysis.format
        slide_ids = [slide.slide_id for slide in analysis.slides]
        if graph.slide_id in slide_ids:
            slide_number = slide_ids.index(graph.slide_id) + 1
    elif graph.format is not None:
        fmt = graph.format

    slide_count = fmt.slide_count or (
        len(analysis.slides) if analysis is not None else 1
    )
    allowed_ids = {
        item.element.id for item in allowed if item.element is not None
    }
    keep = _keep_lines(graph, allowed_ids)
    change = _change_lines(allowed)
    return (
        "Create a close variation of the attached image for JustPost, a "
        "slideshow variation app for TikTok affiliates.\n"
        "\n"
        "The original slideshow has already performed well. Preserve the "
        "creative concept and visual choices that likely made it work while "
        "making only the approved changes below.\n"
        "\n"
        "SLIDESHOW ROLE\n"
        f"This is slide {slide_number} of {slide_count} in a "
        f"{fmt.pacing or 'sequential'} slideshow. Its hook mechanic is "
        f"{fmt.hook_mechanic or 'the same as the original'}, its information "
        f"order is {fmt.information_order or 'unchanged'}, and its payoff style "
        f"is {fmt.payoff_style or 'unchanged'}. Keep this exact tutorial step "
        "and information priority.\n"
        "\n"
        "KEEP EXACTLY\n"
        f"{chr(10).join(keep) if keep else '- (none)'}\n"
        "\n"
        "CHANGE ONLY\n"
        f"{chr(10).join(change) if change else '- (none)'}\n"
        "\n"
        "Use the original image as the visual baseline. Preserve the same "
        "composition, crop, camera angle, perspective, subject identity, pose, "
        "layout, and visual hierarchy. Do not duplicate text, overlays, UI, or "
        "other artifacts. Do not add new controls, labels, subjects, or "
        "decorations. The result should look like another authentic execution "
        "of the same creator's concept, not a redesign."
    )


def run_variation_edit(
    source: Image.Image,
    source_path: Path,
    allowed: list[FilteredEdit],
    graph: SlideGraph,
    analysis: SlideshowAnalysis | None = None,
    client: OpenAI | None = None,
    model: str | None = None,
) -> ScopedEditResult:
    """One whole-image OpenAI edit using a concise, filter-approved prompt."""
    if not allowed:
        rgb = source.convert("RGB")
        return ScopedEditResult(
            image=rgb,
            skipped=True,
            skip_reason="no eligible edit after filter",
        )

    prompt = build_variation_prompt(graph, allowed, analysis)

    client = client or OpenAI()
    model = model or os.environ.get("OPENAI_IMAGE_MODEL", DEFAULT_IMAGE_MODEL)
    rgb = source.convert("RGB")
    with source_path.open("rb") as image_file:
        response = client.images.edit(
            model=model,
            image=image_file,
            prompt=prompt,
            size=openai_size_label(*rgb.size),
            quality="high",
        )
    edited = _image_from_edit_response(response)
    if edited.size != rgb.size:
        edited = edited.resize(rgb.size, Image.Resampling.LANCZOS)
    return ScopedEditResult(image=edited.convert("RGB"), prompt=prompt)


def default_proposals_for_graph(graph) -> list:
    def _priority(element) -> tuple:
        area = element.bbox.w * element.bbox.h
        type_rank = {ElementType.SUBJECT: 0, ElementType.BACKGROUND: 1}.get(
            element.type, 9
        )
        return (type_rank, -area)

    proposals = []
    for element in sorted(graph.editable_elements(), key=_priority):
        if element.type == ElementType.SUBJECT:
            if not element.editable_attributes:
                continue
            locked = ", ".join(element.locked_attributes) or "pose, silhouette, face"
            if element.editable_attributes == ["garment_color"]:
                instruction = (
                    "Change the outfit colors to a visibly different, harmonious "
                    "palette, such as light beige, light brown, or complementary "
                    "muted colors. Keep the same garments and fabric coverage. "
                    f"Do not change {locked}."
                )
            else:
                instruction = (
                    f"Change only {', '.join(element.editable_attributes)} to a "
                    f"visibly different but coherent variation. Do not change {locked}."
                )
            proposals.append(
                ProposedEdit(
                    element_id=element.id,
                    instruction=instruction,
                    target_attributes=list(element.editable_attributes),
                )
            )
            continue
        if element.type == ElementType.BACKGROUND and element.role == EditRole.EDITABLE:
            label = element.label or "background"
            proposals.append(
                ProposedEdit(
                    element_id=element.id,
                    instruction=(
                        f"Alter the {label} slightly with a visibly different but "
                        "coherent color palette, texture, or nearby scenery. Keep "
                        "the same setting type, framing, perspective, and lighting."
                    ),
                )
            )
    return proposals


def save_image(image: Image.Image, path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path)
    return path
