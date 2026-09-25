from __future__ import annotations

from .models import (
    NEVER_IMAGE_EDIT_TYPES,
    EditRole,
    Element,
    ElementType,
    ExtractedElement,
    FormatSpec,
    Permissions,
    SlideGraph,
)


def permissions_for(element_type: ElementType, role: EditRole) -> Permissions:
    if element_type in NEVER_IMAGE_EDIT_TYPES:
        return Permissions(
            editable=False,
            lock_reason=(
                f"type {element_type.value} is never sent to an image model "
                "(composited from the graph)"
            ),
        )
    if role == EditRole.PROTECTED:
        return Permissions(
            editable=False,
            lock_reason="role protected is never eligible for any edit",
        )
    if role == EditRole.CREATOR_SIGNATURE:
        return Permissions(
            editable=False,
            lock_reason=(
                "creator_signature is restyled in composite, not by an image model"
            ),
        )
    if role in {EditRole.PRESERVE_IDENTITY, EditRole.EDITABLE}:
        return Permissions(editable=True)
    return Permissions(
        editable=False,
        lock_reason=f"unknown role {role.value} defaults to locked",
    )


def apply_permissions(
    slide_id: str,
    source_path: str,
    width_px: int,
    height_px: int,
    extracted: list[ExtractedElement],
    format_spec: FormatSpec | None = None,
    ocr_text: str = "",
) -> SlideGraph:
    elements = [
        Element(
            id=item.id,
            type=item.type,
            role=item.role,
            bbox=item.bbox.clamp(),
            label=item.label,
            text=item.text,
            points_to=item.points_to,
            anchors_to=item.anchors_to,
            editable_attributes=list(item.editable_attributes),
            locked_attributes=list(item.locked_attributes),
            permissions=permissions_for(item.type, item.role),
            confidence=item.confidence,
        )
        for item in extracted
    ]
    return SlideGraph(
        slide_id=slide_id,
        source_path=source_path,
        width_px=width_px,
        height_px=height_px,
        ocr_text=ocr_text,
        format=format_spec,
        elements=elements,
    )
