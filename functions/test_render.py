from io import BytesIO

import pytest
from PIL import Image, ImageChops
from pydantic import ValidationError

from justpost.layout_schema import LayoutChoice
from justpost.render import (
    MAX_FONT,
    MIN_FONT,
    PRESETS,
    box_for,
    missing_characters,
    render_slide,
    wrap,
    _font,
)

HOOK = "POV: your lock screen teaches you a new Name of Allah every day"
ANALYSIS = {
    "copy": [
        {"text": "small label", "role": "label", "region": {"x": 0.7, "y": 0.02, "w": 0.2, "h": 0.04}},
        {"text": "the hook", "role": "hook", "region": {"x": 0.1, "y": 0.6, "w": 0.8, "h": 0.08}},
    ]
}


def _png(size=(704, 1536)) -> bytes:
    image = Image.linear_gradient("L").resize(size).convert("RGB")
    buffer = BytesIO()
    image.save(buffer, "PNG")
    return buffer.getvalue()


def _render(text=HOOK, size=(704, 1536), analysis=None, role="hook", **choice):
    return render_slide(
        _png(size), text, LayoutChoice(**choice), ANALYSIS if analysis is None else analysis, role
    )


def _changed_box(outcome, size=(704, 1536)) -> tuple[int, int, int, int]:
    before = Image.open(BytesIO(_png(size))).convert("RGB")
    after = Image.open(BytesIO(outcome.png)).convert("RGB")
    return ImageChops.difference(before, after).getbbox()


def test_the_reference_box_follows_the_copy_block_with_the_blueprint_role():
    box = box_for("reference", ANALYSIS, "hook")
    assert box == {"x": 0.1, "y": 0.55, "w": 0.8, "h": 0.18}


def test_a_small_reference_box_grows_but_stays_in_the_frame():
    box = box_for("reference", ANALYSIS, "label")
    assert (box["w"], box["h"]) == (0.6, 0.18)
    assert box["x"] + box["w"] <= 1 and box["y"] == 0.0


def test_without_a_matching_role_the_first_copy_block_is_used():
    assert box_for("reference", ANALYSIS, "caption")["y"] == 0.0


def test_without_any_slide_text_the_bottom_preset_is_used():
    assert box_for("reference", {"copy": []}, "hook") == PRESETS["bottom"]


@pytest.mark.parametrize("position", ["top", "middle", "bottom"])
def test_presets_ignore_the_analysis(position):
    assert box_for(position, ANALYSIS, "hook") == PRESETS[position]


def test_the_app_cannot_send_a_box_text_or_sizes():
    for extra in ({"box": {"x": 0, "y": 0, "w": 1, "h": 1}}, {"text": "hi"}, {"fontSize": 99}):
        with pytest.raises(ValidationError):
            LayoutChoice.model_validate(extra)
    with pytest.raises(ValidationError):
        LayoutChoice.model_validate({"style": "comic_sans"})


def test_wrap_breaks_between_words_only():
    font = _font("outlined", 40)
    lines = wrap(HOOK, font, 400)
    assert " ".join(lines) == HOOK
    assert all(font.getlength(line) <= 400 for line in lines)
    assert wrap("Supercalifragilisticexpialidocious", font, 100) is None


@pytest.mark.parametrize("style", ["outlined", "white_box", "dark_box"])
def test_text_is_drawn_inside_its_box(style):
    outcome = _render(style=style)
    assert outcome.passed, outcome.report.issues
    left, top, right, bottom = _changed_box(outcome)
    box = outcome.layout["box"]
    width, height = 704, 1536
    assert left >= box["x"] * width - 1 and right <= (box["x"] + box["w"]) * width + 1
    assert top >= box["y"] * height - 1 and bottom <= (box["y"] + box["h"]) * height + 1
    assert MIN_FONT * height <= outcome.font_size_px <= MAX_FONT * height + 1


def test_the_same_layout_scales_with_the_canvas():
    small = _render(size=(704, 1536))
    large = _render(size=(1408, 3072))
    assert small.lines == large.lines
    assert abs(large.font_size_px - 2 * small.font_size_px) <= 2
    s_left, s_top, _, _ = _changed_box(small, (704, 1536))
    l_left, l_top, _, _ = _changed_box(large, (1408, 3072))
    # Whole-pixel font sizes leave a little rounding; compare as fractions.
    assert abs(l_left / 1408 - s_left / 704) <= 0.005
    assert abs(l_top / 3072 - s_top / 1536) <= 0.005


def test_left_alignment_starts_at_the_box_edge():
    outcome = _render(align="left", style="white_box")
    left, _, _, _ = _changed_box(outcome)
    assert abs(left - outcome.layout["box"]["x"] * 704) <= 2


def test_the_output_is_a_clean_png_the_size_of_the_image():
    outcome = _render()
    image = Image.open(BytesIO(outcome.png))
    assert (image.format, image.size, image.mode) == ("PNG", (704, 1536), "RGB")
    assert (outcome.width, outcome.height) == (704, 1536)
    assert outcome.layout["schemaVersion"] == 1


def test_text_that_cannot_fit_fails():
    outcome = _render(text=" ".join(["word"] * 120))
    assert not outcome.passed
    assert outcome.report.issues == ("The text doesn't fit in this position. Try another position.",)


@pytest.mark.parametrize(
    ("text", "missing"),
    [("Ready? 🙂", ["🙂"]), ("أسماء الله الحسنى", ["أ", "س", "م", "ا", "ء", "ل", "ه", "ح", "ن", "ى"])],
)
def test_characters_the_font_cannot_draw_fail(text, missing):
    assert missing_characters(text) == missing
    outcome = _render(text=text)
    assert not outcome.passed
    assert outcome.report.issues[0].startswith("The font can't draw these characters: ")


def test_latin_accents_and_punctuation_are_drawable():
    assert missing_characters("Café — “quotes”, 99% & more!") == []


def test_a_plan_without_text_keeps_the_image_unchanged():
    outcome = _render(text=None)
    assert outcome.passed
    assert _changed_box(outcome) is None
    assert outcome.lines == [] and outcome.font_size_px is None


# keep-clear areas


def _area(label, x, y, w, h):
    return {"label": label, "region": {"x": x, "y": y, "w": w, "h": h}}


# Text fills its box: reference spans y 0.55-0.73, bottom 0.62-0.82, middle 0.4-0.6.
FACE_IN_HOOK_BOX = _area("face", 0.3, 0.62, 0.4, 0.1)


def _keep_clear_render(keep_clear, find_clear_position=False, **choice):
    return render_slide(
        _png(),
        HOOK,
        LayoutChoice(**choice),
        ANALYSIS,
        "hook",
        keep_clear=keep_clear,
        find_clear_position=find_clear_position,
    )


def test_the_text_region_is_recorded_inside_its_box():
    outcome = _keep_clear_render([])
    region, box = outcome.text_region, outcome.layout["box"]
    assert box["y"] - 0.01 <= region["y"] and region["y"] + region["h"] <= box["y"] + box["h"] + 0.01


def test_a_chosen_position_over_a_keep_clear_area_is_refused():
    outcome = _keep_clear_render([FACE_IN_HOOK_BOX])
    assert not outcome.passed
    assert outcome.report.issues == ("The text would cover the face. Try another position.",)


def test_a_small_overlap_is_allowed():
    sliver = _area("drink", 0.0, 0.0, 1.0, 0.42)
    outcome = _keep_clear_render([sliver], position="middle")
    assert outcome.passed


def test_the_first_render_moves_the_text_to_the_next_clear_position():
    outcome = _keep_clear_render([FACE_IN_HOOK_BOX], find_clear_position=True)
    assert outcome.passed
    assert outcome.layout["position"] == "top"


def test_the_fallback_follows_the_order_reference_bottom_top_middle():
    high_face = _area("face", 0.3, 0.1, 0.4, 0.12)
    outcome = _keep_clear_render([FACE_IN_HOOK_BOX, high_face], find_clear_position=True)
    assert outcome.layout["position"] == "middle"


def test_when_no_position_is_clear_the_render_fails():
    everywhere = _area("face", 0.0, 0.0, 1.0, 1.0)
    outcome = _keep_clear_render([everywhere], find_clear_position=True)
    assert not outcome.passed
    assert outcome.report.issues == ("No position keeps the text clear of the image's subject.",)
