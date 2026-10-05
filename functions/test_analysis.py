import copy
import json

import pytest

from justpost.analysis import (
    INSTRUCTIONS,
    USER_TEXT,
    analyze,
    build_instructions,
    check_analysis,
)
from justpost.model_io import ModelError, ModelReply, parse_raw

REGION = {"x": 0.1, "y": 0.6, "w": 0.8, "h": 0.15}


def _sample() -> dict:
    return {
        "schemaVersion": 1,
        "creativeType": "ugc_hook_slide",
        "scene": {
            "environment": "car interior",
            "lighting": "natural daylight",
            "background": "urban street visible outside",
            "cameraStyle": "casual front-facing selfie",
        },
        "subjects": [
            {
                "description": "woman in an olive hijab",
                "position": "center-right",
                "styling": ["olive hijab", "casual top"],
                "faceVisibility": "obscured",
                "holding": "green drink",
                "region": {"x": 0.35, "y": 0.1, "w": 0.6, "h": 0.8},
            }
        ],
        "visualDevices": [
            {
                "type": "graphic_overlay",
                "description": "large pink heart covering the face",
                "role": "privacy and casual UGC styling",
            }
        ],
        "copy": [
            {
                "text": "Here's how to add the 99 Names of Allah on your lock screen",
                "role": "hook",
                "region": REGION,
            }
        ],
        "hookType": "how-to",
        "mechanisms": ["specific utility", "daily novelty"],
        "composition": {
            "orientation": "portrait",
            "subjectWeight": "central",
            "textPlacement": "lower-middle",
            "visualHierarchy": ["subject", "heart graphic", "hook text"],
        },
        "aesthetic": ["UGC", "casual"],
        "centralElements": ["covered face", "how-to hook"],
    }


class ScriptedModel:
    """Returns the queued replies in order and records what was sent."""

    def __init__(self, *replies):
        self.replies = list(replies)
        self.instructions: list[str] = []
        self.user_texts: list[str] = []

    def respond(self, instructions: str, user_text: str, image_webp: bytes) -> ModelReply:
        self.instructions.append(instructions)
        self.user_texts.append(user_text)
        reply = self.replies.pop(0)
        if isinstance(reply, Exception):
            raise reply
        return reply


def _reply(text: str, **kwargs) -> ModelReply:
    return ModelReply(text=text, model="test-model", **kwargs)


def test_a_good_sample_passes():
    analysis, report = check_analysis(_sample(), expected_orientation="portrait")
    assert report.passed and report.status == "passed"
    assert analysis is not None
    assert analysis.model_dump(by_alias=True)["copy"][0]["role"] == "hook"


def test_plain_and_code_fenced_json_both_parse():
    text = json.dumps(_sample())
    assert parse_raw(text)[0] == _sample()
    assert parse_raw(f"```json\n{text}\n```")[0] == _sample()
    assert parse_raw(f"```\n{text}\n```")[0] == _sample()


@pytest.mark.parametrize(
    "text",
    [
        "",
        "   ",
        "Sure! Here is the analysis: {\"schemaVersion\": 1}",
        "{\"schemaVersion\": 1} Hope this helps.",
        "[1, 2, 3]",
        "I'm sorry, I can't help with that.",
    ],
)
def test_replies_that_are_not_one_json_object_fail(text):
    data, issues = parse_raw(text)
    assert data is None
    assert issues


def test_missing_and_unknown_fields_fail():
    missing = _sample()
    del missing["scene"]
    _, report = check_analysis(missing)
    assert not report.passed
    assert any(issue.startswith("scene") for issue in report.issues)

    extra = _sample()
    extra["mustPreserve"] = ["hijab"]
    _, report = check_analysis(extra)
    assert not report.passed
    assert any("mustPreserve" in issue for issue in report.issues)


@pytest.mark.parametrize(
    "region",
    [
        {"x": -0.1, "y": 0.5, "w": 0.5, "h": 0.1},
        {"x": 0.2, "y": 0.5, "w": 1.2, "h": 0.1},
        {"x": 0.7, "y": 0.5, "w": 0.5, "h": 0.1},
        {"x": 0.2, "y": 0.5, "w": 0.0, "h": 0.1},
        {"x": 120, "y": 800, "w": 300, "h": 90},
    ],
)
def test_regions_outside_the_slide_fail(region):
    data = _sample()
    data["copy"][0]["region"] = region
    _, report = check_analysis(data)
    assert not report.passed
    assert any(issue.startswith("copy.0.region") for issue in report.issues)


def test_prescriptive_wording_fails_outside_the_slides_own_text():
    data = _sample()
    data["subjects"][0]["styling"].append("hijab color must stay olive")
    _, report = check_analysis(data)
    assert not report.passed
    assert report.issues == (
        "subjects.0.styling.2: states a rule instead of describing the slide",
    )

    data = _sample()
    data["copy"][0]["text"] = "You must try this before you die"
    _, report = check_analysis(data)
    assert report.passed


def test_orientation_must_match_the_ingested_slide():
    _, report = check_analysis(_sample(), expected_orientation="landscape")
    assert not report.passed
    assert "composition.orientation" in report.issues[0]


def test_the_first_passing_attempt_is_returned_with_its_raw_text():
    raw = json.dumps(_sample())
    model = ScriptedModel(_reply(raw, input_tokens=900, output_tokens=400))

    outcome = analyze(b"webp", model, expected_orientation="portrait")

    assert outcome.passed
    assert outcome.result["creativeType"] == "ugc_hook_slide"
    assert len(outcome.attempts) == 1
    record = outcome.attempts[0].to_record()
    assert record["rawText"] == raw
    assert record["status"] == "passed"
    assert record["inputTokens"] == 900
    assert model.instructions == [INSTRUCTIONS]
    assert model.user_texts == [USER_TEXT]


def test_a_failed_attempt_is_retried_with_its_issues():
    model = ScriptedModel(_reply("Here you go!"), _reply(json.dumps(_sample())))

    outcome = analyze(b"webp", model)

    assert outcome.passed
    assert [a.report.status for a in outcome.attempts] == ["failed", "passed"]
    assert outcome.attempts[0].raw_text == "Here you go!"
    assert model.instructions[1] == build_instructions(
        ("The reply was not a single JSON object.",)
    )


def test_nothing_is_returned_when_every_attempt_fails():
    bad = _sample()
    bad["composition"]["orientation"] = "diagonal"
    model = ScriptedModel(
        _reply(json.dumps(bad)), _reply("no", refusal=True)
    )

    outcome = analyze(b"webp", model)

    assert not outcome.passed
    assert outcome.result is None
    assert [a.report.status for a in outcome.attempts] == ["failed", "failed"]
    assert outcome.attempts[1].report.issues == ("The model declined the request.",)


def test_model_errors_count_as_failed_attempts():
    model = ScriptedModel(ModelError("timeout"), _reply(json.dumps(_sample())))

    outcome = analyze(b"webp", model)

    assert outcome.passed
    assert outcome.attempts[0].raw_text == ""
    assert outcome.attempts[0].report.issues == ("The model request failed.",)


def test_the_sample_is_not_mutated_by_checking():
    data = _sample()
    snapshot = copy.deepcopy(data)
    check_analysis(data)
    assert data == snapshot
