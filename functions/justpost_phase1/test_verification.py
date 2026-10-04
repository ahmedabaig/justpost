import numpy as np
from PIL import Image, ImageDraw

from .models import BBox, EditRole, ElementType, ExtractedElement
from .policy import apply_permissions
from .verification import restore_locked_ink, verify_locked_regions


def _slide(sticker_fill: tuple[int, int, int], background_fill: tuple[int, int, int]) -> Image.Image:
    image = Image.new("RGB", (100, 100), background_fill)
    draw = ImageDraw.Draw(image)
    draw.rectangle((40, 40, 70, 70), fill=sticker_fill)
    return image


def _graph():
    return apply_permissions(
        slide_id="t",
        source_path="t.jpg",
        width_px=100,
        height_px=100,
        extracted=[
            ExtractedElement(
                id="bg",
                type=ElementType.BACKGROUND,
                role=EditRole.EDITABLE,
                bbox=BBox(x=0.0, y=0.0, w=1.0, h=1.0),
                label="photo",
            ),
            ExtractedElement(
                id="sticker",
                type=ElementType.TEXT,
                role=EditRole.PROTECTED,
                bbox=BBox(x=0.3, y=0.3, w=0.5, h=0.5),
                label="caption",
                text="hello",
            ),
        ],
    )


def test_background_swap_does_not_fail_unchanged_sticker():
    original = _slide((255, 255, 255), (200, 40, 40))
    edited = _slide((255, 255, 255), (40, 80, 200))
    result = verify_locked_regions(original, edited, _graph())
    sticker = next(score for score in result.scores if score.element_id == "sticker")
    assert sticker.used_ink_mask is True
    assert sticker.passed is True
    assert result.passed is True


def test_changed_sticker_still_fails():
    original = _slide((255, 255, 255), (200, 40, 40))
    edited = _slide((0, 0, 0), (40, 80, 200))
    result = verify_locked_regions(original, edited, _graph())
    sticker = next(score for score in result.scores if score.element_id == "sticker")
    assert sticker.passed is False
    assert result.fallback_to_original is True


def test_restore_puts_original_sticker_back_and_keeps_new_photo():
    original = _slide((255, 255, 255), (200, 40, 40))
    edited = _slide((10, 10, 10), (40, 80, 200))
    restored = restore_locked_ink(original, edited, _graph())
    result = verify_locked_regions(original, restored, _graph())
    sticker = next(score for score in result.scores if score.element_id == "sticker")
    assert sticker.passed is True
    assert result.passed is True
    assert restored.getpixel((10, 10)) == (40, 80, 200)
    assert restored.getpixel((50, 50)) == (255, 255, 255)


def test_restore_skips_full_frame_chrome():
    original = Image.new("RGB", (100, 100), (200, 40, 40))
    edited = Image.new("RGB", (100, 100), (40, 80, 200))
    graph = apply_permissions(
        slide_id="t",
        source_path="t.jpg",
        width_px=100,
        height_px=100,
        extracted=[
            ExtractedElement(
                id="canvas",
                type=ElementType.UI_ELEMENT,
                role=EditRole.PROTECTED,
                bbox=BBox(x=0.0, y=0.0, w=1.0, h=1.0),
                label="editor canvas",
            ),
        ],
    )
    restored = restore_locked_ink(original, edited, graph)
    assert np.array_equal(np.asarray(restored), np.asarray(edited))
