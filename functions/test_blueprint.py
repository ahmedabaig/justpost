import copy
import json

import pytest

from justpost.blueprint import (
    INSTRUCTIONS,
    build,
    build_instructions,
    check_blueprint,
    path_exists,
    stamp_ai_draft,
)
from justpost.model_io import ModelReply
from test_analysis import ScriptedModel, _sample

RUN_ID = "run1"


def _analysis() -> dict:
    return _sample()


def _ai_reply() -> dict:
    """A draft as the model returns it: no IDs, origins or analysis run."""
    return {
        "schemaVersion": 1,
        "creativeFamily": "ugc_car_selfie_hook",
        "objective": "Introduce a lock-screen feature through a casual UGC hook",
        "requiredPrinciples": [
            {"text": "Creator's face is hidden by a graphic", "basis": ["visualDevices.0"]},
            {"text": "Shot inside a car", "basis": ["scene.environment"]},
            {"text": "Large readable how-to hook", "basis": ["copy.0", "hookType"]},
        ],
        "preferredPrinciples": [
            {"text": "Natural daylight", "basis": ["scene.lighting"]},
        ],
        "variationDimensions": [
            {"name": "Hijab color", "examples": ["cream", "black"], "basis": ["subjects.0.styling"]},
            {"name": "Drink", "examples": ["iced coffee", "matcha"], "basis": ["subjects.0.holding"]},
            {"name": "Face-cover graphic", "examples": ["white flower"], "basis": ["visualDevices.0"]},
        ],
        "forbiddenDrift": [
            {"text": "Turning it into a studio advertisement", "basis": ["scene.cameraStyle"]},
            {"text": "Showing the face clearly", "basis": ["subjects.0.faceVisibility"]},
        ],
        "copyStrategy": {
            "role": "hook",
            "primaryPattern": "explain a concrete utility",
            "secondaryPattern": None,
        },
    }


def _draft() -> dict:
    return stamp_ai_draft(_ai_reply(), RUN_ID)


def _check(data, source="ai", analysis=None, run_id=RUN_ID):
    return check_blueprint(data, analysis or _analysis(), run_id, source)


def test_a_good_draft_passes():
    blueprint, report = _check(_draft())
    assert report.passed, report.issues
    assert blueprint.requiredPrinciples[0].id == "req1"
    assert blueprint.variationDimensions[2].id == "var3"
    assert {item.origin for item in blueprint.forbiddenDrift} == {"ai"}


def test_stamping_overrides_any_ids_origins_or_run_from_the_model():
    reply = _ai_reply()
    reply["analysisRunId"] = "made-up"
    reply["requiredPrinciples"][0]["origin"] = "user"
    reply["requiredPrinciples"][0]["id"] = "dup"
    stamped = stamp_ai_draft(reply, RUN_ID)
    assert stamped["analysisRunId"] == RUN_ID
    assert stamped["requiredPrinciples"][0] == {
        "text": "Creator's face is hidden by a graphic",
        "basis": ["visualDevices.0"],
        "id": "req1",
        "origin": "ai",
    }
    assert reply["analysisRunId"] == "made-up"


@pytest.mark.parametrize(
    ("path", "exists"),
    [
        ("scene", True),
        ("scene.lighting", True),
        ("subjects.0.faceVisibility", True),
        ("copy.0", True),
        ("subjects.3", False),
        ("scene.mood", False),
        ("copy.x", False),
    ],
)
def test_path_exists(path, exists):
    assert path_exists(_analysis(), path) is exists


def test_a_basis_path_that_is_not_in_the_analysis_fails():
    draft = _draft()
    draft["requiredPrinciples"][1]["basis"] = ["scene.vehicle"]
    _, report = _check(draft)
    assert not report.passed
    assert "requiredPrinciples.1.basis: 'scene.vehicle' is not in the analysis" in report.issues


def test_ai_items_must_cite_a_basis():
    draft = _draft()
    draft["forbiddenDrift"][0]["basis"] = []
    _, report = _check(draft)
    assert "forbiddenDrift.0.basis: cite at least one analysis path" in report.issues


def test_the_same_idea_in_two_sections_fails():
    draft = _draft()
    draft["variationDimensions"][0]["name"] = "Shot inside a car"
    _, report = _check(draft)
    assert not report.passed
    assert "variationDimensions.0: repeats requiredPrinciples.1" in report.issues


def test_duplicate_ids_fail():
    draft = _draft()
    draft["forbiddenDrift"][0]["id"] = "req1"
    _, report = _check(draft, source="user")
    assert "forbiddenDrift.0.id: 'req1' is used twice" in report.issues


def test_ai_minimums_are_stricter_than_user_minimums():
    draft = _draft()
    draft["requiredPrinciples"] = draft["requiredPrinciples"][:1]
    draft["forbiddenDrift"] = []

    _, ai_report = _check(draft, source="ai")
    assert not ai_report.passed
    assert any(issue.startswith("requiredPrinciples: needs at least 3") for issue in ai_report.issues)
    assert any(issue.startswith("forbiddenDrift: needs at least 2") for issue in ai_report.issues)

    _, user_report = _check(draft, source="user")
    assert user_report.passed, user_report.issues


def test_users_still_need_one_must_keep_and_one_can_vary():
    draft = _draft()
    draft["requiredPrinciples"] = []
    draft["variationDimensions"] = []
    _, report = _check(draft, source="user")
    assert not report.passed
    assert len([i for i in report.issues if "needs at least 1" in i]) == 2


def test_user_added_items_need_no_basis_but_must_cite_real_paths_if_they_do():
    draft = _draft()
    draft["requiredPrinciples"].append(
        {"id": "u1", "text": "Keep the arabic calligraphy feel", "basis": [], "origin": "user"}
    )
    _, report = _check(draft, source="user")
    assert report.passed, report.issues

    draft["requiredPrinciples"][-1]["basis"] = ["calligraphy"]
    _, report = _check(draft, source="user")
    assert not report.passed


def test_section_maximums_and_unknown_fields_fail():
    draft = _draft()
    draft["forbiddenDrift"] = [
        {"id": f"n{i}", "text": f"Distinct drift number {i}", "basis": [], "origin": "user"}
        for i in range(9)
    ]
    _, report = _check(draft, source="user")
    assert not report.passed

    draft = _draft()
    draft["confidence"] = 0.9
    _, report = _check(draft)
    assert any("confidence" in issue for issue in report.issues)


def test_the_copy_role_must_be_used_on_the_slide():
    draft = _draft()
    draft["copyStrategy"]["role"] = "call_to_action"
    _, report = _check(draft)
    assert any(issue.startswith("copyStrategy.role") for issue in report.issues)

    no_text = _analysis()
    no_text["copy"] = []
    draft = _draft()
    draft["requiredPrinciples"][2]["basis"] = ["hookType"]
    _, report = _check(draft, analysis=no_text)
    assert "copyStrategy.role: the slide has no text, so use 'none'" in report.issues
    draft["copyStrategy"]["role"] = "none"
    _, report = _check(draft, analysis=no_text)
    assert report.passed, report.issues


def test_a_draft_from_an_earlier_analysis_fails():
    _, report = _check(_draft(), source="user", run_id="run2")
    assert report.issues == (
        "analysisRunId: built from an earlier analysis; rebuild the draft",
    )


def test_build_sends_the_analysis_and_retries_with_feedback():
    bad = _ai_reply()
    bad["requiredPrinciples"] = bad["requiredPrinciples"][:1]
    model = ScriptedModel(
        ModelReply(json.dumps(bad), "m"), ModelReply(json.dumps(_ai_reply()), "m")
    )

    outcome = build(_analysis(), RUN_ID, b"webp", model)

    assert outcome.passed
    assert [a.report.status for a in outcome.attempts] == ["failed", "passed"]
    assert outcome.result["analysisRunId"] == RUN_ID
    assert outcome.result["requiredPrinciples"][0]["origin"] == "ai"
    assert model.instructions[0] == INSTRUCTIONS
    assert model.instructions[1] == build_instructions(outcome.attempts[0].report.issues)
    assert '"creativeType": "ugc_hook_slide"' in model.user_texts[0]


def test_the_reply_is_not_mutated_by_checking():
    reply = _ai_reply()
    snapshot = copy.deepcopy(reply)
    stamp_ai_draft(reply, RUN_ID)
    assert reply == snapshot
