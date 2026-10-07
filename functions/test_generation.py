from io import BytesIO

import pytest
from PIL import Image

from justpost.generation import (
    build_request,
    check_image,
    find_plan,
    generate,
    output_size,
    plans_are_stale,
)
from justpost.model_io import ImageReply, ModelError, ModelRefusal
from test_blueprint import RUN_ID, _draft
from test_planning import VERSION, _plans


def _png(size=(704, 1536), color=None, mode="RGB", **save) -> bytes:
    if color is None:
        image = Image.linear_gradient("L").resize(size).convert(mode)
    else:
        image = Image.new(mode, size, color)
    buffer = BytesIO()
    image.save(buffer, "PNG", **save)
    return buffer.getvalue()


class ScriptedImageModel:
    """Returns the scripted replies in order; an exception is raised instead."""

    def __init__(self, *replies):
        self.replies = list(replies)
        self.calls: list[tuple[str, bytes, str]] = []

    def edit(self, request: str, reference_webp: bytes, size: str) -> ImageReply:
        self.calls.append((request, reference_webp, size))
        reply = self.replies.pop(0)
        if isinstance(reply, Exception):
            raise reply
        return reply


def _plan(plan_id="p1") -> dict:
    return find_plan(_plans(), plan_id)


@pytest.mark.parametrize(
    ("source", "expected"),
    [
        ((1179, 2556), (704, 1536)),
        ((1080, 1920), (864, 1536)),
        ((1000, 1000), (1536, 1536)),
        ((1920, 1080), (1536, 864)),
        ((100, 1000), (512, 1536)),
        ((5000, 100), (1536, 512)),
    ],
)
def test_output_size_keeps_the_slide_shape_within_model_limits(source, expected):
    width, height = output_size(*source)
    assert (width, height) == expected
    assert width % 16 == 0 and height % 16 == 0
    assert 1 / 3 <= width / height <= 3


def test_plans_go_stale_when_the_blueprint_or_analysis_changes():
    plans = _plans()
    assert not plans_are_stale(plans, VERSION, RUN_ID)
    assert plans_are_stale(plans, VERSION + 1, RUN_ID)
    assert plans_are_stale(plans, VERSION, "run2")


def test_find_plan():
    assert find_plan(_plans(), "p2")["title"] == "Matcha and flowers"
    assert find_plan(_plans(), "p9") is None


def test_the_request_lists_keep_changes_and_never_items():
    request = build_request(_draft(), _plan())

    assert "- Creator's face is hidden by a graphic" in request
    assert "- Natural daylight (preferred)" in request
    assert "- Hijab color: warm cream\n- Drink: iced coffee" in request
    assert "- Showing the face clearly" in request
    assert request.index("Keep:") < request.index("For this variation:") < request.index("Never:")
    assert request.endswith("continue the scene instead.")


def test_the_request_never_contains_the_slide_text():
    plan = _plan()
    request = build_request(_draft(), plan)
    assert plan["copy"]["text"] not in request
    assert plan["copy"]["pattern"] not in request


def test_a_good_image_passes_and_loses_its_metadata():
    data = _png(icc_profile=b"fake-profile")
    png, report = check_image(data, (704, 1536))

    assert report.passed
    clean = Image.open(BytesIO(png))
    assert clean.format == "PNG"
    assert clean.size == (704, 1536)
    assert clean.mode == "RGB"
    assert "icc_profile" not in clean.info


def test_transparent_images_are_flattened():
    png, report = check_image(_png(mode="RGBA"), (704, 1536))
    assert report.passed
    assert Image.open(BytesIO(png)).mode == "RGB"


@pytest.mark.parametrize(
    ("data", "issue"),
    [
        (b"not an image", "The reply was not a readable image."),
        (_png(size=(1024, 1536)), "The image is 1024x1536, not the requested 704x1536."),
        (_png(color="black"), "The image is blank or a single color."),
        (_png(color=(200, 30, 90)), "The image is blank or a single color."),
    ],
)
def test_bad_images_fail_with_a_reason(data, issue):
    png, report = check_image(data, (704, 1536))
    assert png is None
    assert report.issues == (issue,)


def test_non_png_images_fail():
    buffer = BytesIO()
    Image.linear_gradient("L").resize((704, 1536)).convert("RGB").save(buffer, "JPEG")
    _, report = check_image(buffer.getvalue(), (704, 1536))
    assert report.issues == ("The image is JPEG, not PNG.",)


def test_generate_sends_one_request_and_checks_the_reply():
    model = ScriptedImageModel(ImageReply(_png(), "image-model", 10, 20))
    outcome = generate("request", b"webp", (704, 1536), model)

    assert outcome.passed
    assert model.calls == [("request", b"webp", "704x1536")]
    assert (outcome.model, outcome.input_tokens, outcome.output_tokens) == ("image-model", 10, 20)


@pytest.mark.parametrize(
    ("reply", "issue"),
    [
        (ModelRefusal("moderation_blocked"), "The image model declined this plan."),
        (ModelError("Timeout"), "The image request failed."),
        (ImageReply(_png(color="white"), "m"), "The image is blank or a single color."),
    ],
)
def test_failed_generations_are_not_retried(reply, issue):
    model = ScriptedImageModel(reply)
    outcome = generate("request", b"webp", (704, 1536), model)
    assert not outcome.passed
    assert outcome.report.issues == (issue,)
    assert len(model.calls) == 1
