from .models import BBox, EditRole, ElementType, ExtractedElement, ProposedEdit
from .permission_filter import filter_edits
from .policy import apply_permissions
from .scoped_edit import default_proposals_for_graph


def _graph():
    return apply_permissions(
        slide_id="t",
        source_path="t.jpg",
        width_px=100,
        height_px=100,
        extracted=[
            ExtractedElement(
                id="face",
                type=ElementType.SUBJECT,
                role=EditRole.PRESERVE_IDENTITY,
                bbox=BBox(x=0.1, y=0.1, w=0.2, h=0.2),
                label="creator",
                editable_attributes=["garment_color"],
                locked_attributes=["pose", "silhouette", "face_visibility"],
            ),
            ExtractedElement(
                id="bg",
                type=ElementType.BACKGROUND,
                role=EditRole.EDITABLE,
                bbox=BBox(x=0.0, y=0.0, w=0.5, h=0.5),
                label="wall",
            ),
            ExtractedElement(
                id="clock",
                type=ElementType.UI_ELEMENT,
                role=EditRole.PROTECTED,
                bbox=BBox(x=0.4, y=0.0, w=0.2, h=0.1),
                label="lock screen time",
            ),
            ExtractedElement(
                id="caption",
                type=ElementType.TEXT,
                role=EditRole.EDITABLE,
                bbox=BBox(x=0.2, y=0.7, w=0.6, h=0.15),
                label="hook text",
                text="tap customize",
            ),
        ],
    )


def test_protected_ui_is_rejected():
    results = filter_edits(
        _graph(),
        [ProposedEdit(element_id="clock", instruction="redraw the clock")],
    )
    assert results[0].allowed is False
    assert "protected" in results[0].reason


def test_text_is_never_sent_to_image_model():
    results = filter_edits(
        _graph(),
        [ProposedEdit(element_id="caption", instruction="rewrite the caption")],
    )
    assert results[0].allowed is False
    assert "never sent" in results[0].reason


def test_preserve_identity_rejects_locked_attribute():
    results = filter_edits(
        _graph(),
        [
            ProposedEdit(
                element_id="face",
                instruction="change the face",
                target_attributes=["face_visibility"],
            )
        ],
    )
    assert results[0].allowed is False


def test_preserve_identity_allows_listed_attribute():
    results = filter_edits(
        _graph(),
        [
            ProposedEdit(
                element_id="face",
                instruction="shift garment_color only",
                target_attributes=["garment_color"],
            )
        ],
    )
    assert results[0].allowed is True


def test_preserve_identity_requires_target_attributes():
    results = filter_edits(
        _graph(),
        [ProposedEdit(element_id="face", instruction="make it better")],
    )
    assert results[0].allowed is False


def test_editable_background_is_allowed():
    results = filter_edits(
        _graph(),
        [ProposedEdit(element_id="bg", instruction="warm the wall")],
    )
    assert results[0].allowed is True


def test_default_proposals_skip_text_and_require_subject_attributes():
    proposals = default_proposals_for_graph(_graph())
    ids = [item.element_id for item in proposals]
    assert "caption" not in ids
    assert "clock" not in ids
    assert "bg" in ids
    face = next(item for item in proposals if item.element_id == "face")
    assert face.target_attributes == ["garment_color"]


def test_unknown_element_is_rejected():
    results = filter_edits(
        _graph(),
        [ProposedEdit(element_id="nope", instruction="whatever")],
    )
    assert results[0].allowed is False
