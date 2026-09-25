"""Security boundary: model output is a proposal; this check is the guarantee."""

from __future__ import annotations

from .models import (
    NEVER_IMAGE_EDIT_TYPES,
    EditRole,
    FilteredEdit,
    ProposedEdit,
    SlideGraph,
)


def filter_edits(graph: SlideGraph, proposals: list[ProposedEdit]) -> list[FilteredEdit]:
    by_id = {element.id: element for element in graph.elements}
    results: list[FilteredEdit] = []
    for proposal in proposals:
        element = by_id.get(proposal.element_id)
        if element is None:
            results.append(
                FilteredEdit(
                    proposal=proposal,
                    allowed=False,
                    reason=f"unknown element_id {proposal.element_id}",
                )
            )
            continue
        if element.type in NEVER_IMAGE_EDIT_TYPES:
            results.append(
                FilteredEdit(
                    proposal=proposal,
                    allowed=False,
                    reason=(
                        f"type {element.type.value} is never sent to an image model"
                    ),
                    element=element,
                )
            )
            continue
        if element.role == EditRole.PROTECTED:
            results.append(
                FilteredEdit(
                    proposal=proposal,
                    allowed=False,
                    reason="role protected is never eligible for any edit",
                    element=element,
                )
            )
            continue
        if not element.permissions.editable:
            results.append(
                FilteredEdit(
                    proposal=proposal,
                    allowed=False,
                    reason=element.permissions.lock_reason
                    or f"element {element.id} is locked",
                    element=element,
                )
            )
            continue
        if element.role == EditRole.PRESERVE_IDENTITY:
            allowed_attrs = set(element.editable_attributes)
            if not allowed_attrs:
                results.append(
                    FilteredEdit(
                        proposal=proposal,
                        allowed=False,
                        reason=(
                            f"preserve_identity {element.id} has no editable_attributes"
                        ),
                        element=element,
                    )
                )
                continue
            targets = set(proposal.target_attributes)
            if not targets:
                results.append(
                    FilteredEdit(
                        proposal=proposal,
                        allowed=False,
                        reason=(
                            "preserve_identity edits must list target_attributes "
                            "from editable_attributes"
                        ),
                        element=element,
                    )
                )
                continue
            extra = targets - allowed_attrs
            if extra:
                results.append(
                    FilteredEdit(
                        proposal=proposal,
                        allowed=False,
                        reason=(
                            f"preserve_identity forbids attributes {sorted(extra)}; "
                            f"editable_attributes={sorted(allowed_attrs)}"
                        ),
                        element=element,
                    )
                )
                continue
        results.append(
            FilteredEdit(
                proposal=proposal,
                allowed=True,
                reason="element passed the permission filter",
                element=element,
            )
        )
    return results


def allowed_edits(filtered: list[FilteredEdit]) -> list[FilteredEdit]:
    return [item for item in filtered if item.allowed]
