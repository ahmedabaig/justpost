import json

import pytest

from justpost.model_io import ModelError
from justpost.validation import (
    ARTIFACTS,
    TEXT_IN_IMAGE,
    check_reply,
    questions_for,
    validate,
)
from test_analysis import ScriptedModel, _reply
from test_generation import _png
from test_planning import _blueprint, _plans

FACE = {"label": "face", "region": {"x": 0.3, "y": 0.2, "w": 0.3, "h": 0.2}}


def _plan() -> dict:
    return _plans()["plans"][0]


def _questions():
    return questions_for(_blueprint(), _plan())


def _answers(overrides: dict[str, str] | None = None, keep_clear=None, drop=(), extra=()) -> dict:
    """A reply answering every question the way a passing image would."""
    overrides = overrides or {}
    checks = [
        {
            "id": question.id,
            "answer": overrides.get(question.id, question.expected or "yes"),
            "note": "seen",
        }
        for question in _questions()
        if question.id not in drop
    ]
    checks += [{"id": check_id, "answer": "yes", "note": ""} for check_id in extra]
    return {"schemaVersion": 1, "checks": checks, "keepClear": [FACE] if keep_clear is None else keep_clear}


def test_questions_cover_the_blueprint_the_plan_and_the_fixed_checks():
    ids = [question.id for question in _questions()]
    assert ids == [
        "required:req1",
        "required:req2",
        "required:req3",
        "forbidden:never1",
        "forbidden:never2",
        "change:1",
        "change:2",
        TEXT_IN_IMAGE,
        ARTIFACTS,
        "preferred:pref1",
    ]
    change = next(q for q in _questions() if q.id == "change:1")
    assert change.subject == "Hijab color: warm cream"


def test_a_reply_meeting_every_expectation_passes():
    verdict, report = check_reply(_answers(), _questions())
    assert report.passed
    assert verdict.passed and verdict.reasons == []
    assert verdict.keep_clear == [FACE]
    assert {check["id"]: check["passed"] for check in verdict.checks}["preferred:pref1"] is None


@pytest.mark.parametrize(
    ("check_id", "answer", "reason"),
    [
        ("required:req2", "no", "Missing: Shot inside a car"),
        ("required:req2", "unsure", "Couldn't confirm: Shot inside a car"),
        ("forbidden:never2", "yes", "Not allowed: Showing the face clearly"),
        ("forbidden:never2", "unsure", "Couldn't rule out: Showing the face clearly"),
        ("change:2", "no", "Not changed: Drink: iced coffee"),
        (TEXT_IN_IMAGE, "yes", "The image has its own text in it."),
        (TEXT_IN_IMAGE, "unsure", "Couldn't rule out text in the image."),
        (ARTIFACTS, "yes", "The image has visible glitches."),
    ],
)
def test_a_wrong_or_unsure_answer_rejects_the_image(check_id, answer, reason):
    verdict, report = check_reply(_answers({check_id: answer}), _questions())
    assert report.passed
    assert not verdict.passed
    assert verdict.reasons == [reason]


def test_preferred_principles_never_decide_the_verdict():
    verdict, _ = check_reply(_answers({"preferred:pref1": "no"}), _questions())
    assert verdict.passed


@pytest.mark.parametrize(
    ("kwargs", "issue"),
    [
        ({"drop": ("change:1",)}, "'change:1' has no answer."),
        ({"extra": ("required:made_up",)}, "'required:made_up' is not one of the questions."),
        ({"extra": ("artifacts",)}, "'artifacts' is answered more than once."),
    ],
)
def test_every_question_must_be_answered_exactly_once(kwargs, issue):
    verdict, report = check_reply(_answers(**kwargs), _questions())
    assert verdict is None
    assert issue in report.issues


@pytest.mark.parametrize(
    "data",
    [
        _answers({"artifacts": "maybe"}),
        _answers(keep_clear=[{"label": "face", "region": {"x": 0.8, "y": 0.2, "w": 0.5, "h": 0.2}}]),
        _answers(keep_clear=[FACE] * 7),
        {**_answers(), "verdict": "looks great"},
    ],
)
def test_malformed_replies_fail_the_attempt(data):
    verdict, report = check_reply(data, _questions())
    assert verdict is None and not report.passed


def test_validate_sends_both_images_and_retries_with_feedback():
    model = ScriptedModel(
        _reply(json.dumps(_answers(drop=("artifacts",)))),
        _reply(json.dumps(_answers())),
    )
    outcome = validate(model, _blueprint(), _plan(), b"reference", _png())

    assert outcome.status == "passed"
    assert len(outcome.attempts) == 2
    assert "'artifacts' has no answer." in model.instructions[1]
    reference, generated = model.images[0]
    assert reference == b"reference"
    assert generated[:4] == b"RIFF"
    assert "change:1: Was this planned change made?" in model.user_texts[0]

    record = outcome.to_record()
    assert record["status"] == "passed"
    assert record["model"] == "test-model"
    assert len(record["attempts"]) == 2


def test_a_rejected_image_lists_its_reasons():
    model = ScriptedModel(_reply(json.dumps(_answers({"forbidden:never2": "yes"}))))
    outcome = validate(model, _blueprint(), _plan(), b"reference", _png())
    assert outcome.status == "rejected"
    assert outcome.reasons == ["Not allowed: Showing the face clearly"]


def test_an_image_that_cannot_be_checked_is_unverified():
    model = ScriptedModel(ModelError("down"), _reply("not json"))
    outcome = validate(model, _blueprint(), _plan(), b"reference", _png())
    assert outcome.status == "unverified"
    assert outcome.reasons == ["The image couldn't be checked."]
    assert outcome.to_record()["checks"] == []
