import copy
import json

import pytest

from justpost.model_io import ModelReply
from justpost.planning import (
    INSTRUCTIONS,
    build_instructions,
    change_limits,
    check_plans,
    plan,
    stamp_ai_draft,
)
from test_analysis import ScriptedModel, _sample
from test_blueprint import RUN_ID, _draft

VERSION = 2


def _blueprint() -> dict:
    return _draft()


def _ai_reply() -> dict:
    """Plans as the model returns them: no IDs, origins, blueprint version or run."""
    return {
        "schemaVersion": 1,
        "plans": [
            {
                "title": "Cozy coffee run",
                "changes": [
                    {"dimensionId": "var1", "value": "warm cream"},
                    {"dimensionId": "var2", "value": "iced coffee"},
                ],
                "copy": {
                    "text": "POV: your lock screen teaches you a new Name of Allah every day",
                    "pattern": "POV",
                },
            },
            {
                "title": "Matcha and flowers",
                "changes": [
                    {"dimensionId": "var2", "value": "matcha latte"},
                    {"dimensionId": "var3", "value": "small white flower"},
                ],
                "copy": {
                    "text": "How to put the 99 Names of Allah on your lock screen",
                    "pattern": "how-to",
                },
            },
        ],
    }


def _plans(reply=None) -> dict:
    return stamp_ai_draft(reply or _ai_reply(), RUN_ID, VERSION)


def _check(data, source="ai", count=2, blueprint=None, version=VERSION, run_id=RUN_ID):
    expected = count if source == "ai" else None
    return check_plans(data, blueprint or _blueprint(), version, run_id, source, expected)


def test_good_plans_pass():
    plan_set, report = _check(_plans())
    assert report.passed, report.issues
    assert [p.id for p in plan_set.plans] == ["p1", "p2"]
    assert {p.origin for p in plan_set.plans} == {"ai"}
    assert plan_set.blueprintVersion == VERSION


def test_stamping_overrides_ids_origins_version_and_run_from_the_model():
    reply = _ai_reply()
    reply["blueprintVersion"] = 99
    reply["analysisRunId"] = "made-up"
    reply["plans"][0]["id"] = "u1"
    reply["plans"][0]["origin"] = "user"
    stamped = stamp_ai_draft(reply, RUN_ID, VERSION)
    assert stamped["blueprintVersion"] == VERSION
    assert stamped["analysisRunId"] == RUN_ID
    assert stamped["plans"][0]["id"] == "p1"
    assert stamped["plans"][0]["origin"] == "ai"
    assert reply["blueprintVersion"] == 99


def test_the_ai_must_write_the_requested_number_of_plans():
    _, report = _check(_plans(), count=3)
    assert "plans: write exactly 3, not 2" in report.issues


def test_users_may_keep_one_to_five_plans():
    plans = _plans()
    plans["plans"] = plans["plans"][:1]
    _, report = _check(plans, source="user")
    assert report.passed, report.issues

    plans["plans"] = []
    _, report = _check(plans, source="user")
    assert "plans: keep between 1 and 5" in report.issues


def test_a_change_must_use_a_can_vary_dimension_once():
    plans = _plans()
    plans["plans"][0]["changes"][1]["dimensionId"] = "req1"
    _, report = _check(plans)
    assert any("'req1' is not a 'can vary' dimension" in i for i in report.issues)

    plans = _plans()
    plans["plans"][0]["changes"][1]["dimensionId"] = "var1"
    _, report = _check(plans)
    assert "plans.0.changes.1.dimensionId: 'var1' is changed twice" in report.issues


@pytest.mark.parametrize(
    ("dimensions", "source", "limits"),
    [(1, "ai", (1, 1)), (2, "ai", (2, 2)), (3, "ai", (2, 2)), (6, "ai", (2, 4)), (6, "user", (1, 6))],
)
def test_change_limits(dimensions, source, limits):
    assert change_limits(dimensions, source) == limits


def test_the_ai_may_not_change_everything_at_once():
    plans = _plans()
    plans["plans"][0]["changes"].append({"dimensionId": "var3", "value": "beige star"})
    _, report = _check(plans)
    assert "plans.0.changes: change 2 dimensions, not 3" in report.issues

    _, report = _check(plans, source="user")
    assert report.passed, report.issues


def test_a_change_that_repeats_a_never_item_fails():
    plans = _plans()
    plans["plans"][0]["changes"][0]["value"] = "showing the face clearly"
    _, report = _check(plans)
    assert "plans.0.changes.0.value: matches 'never' item never2" in report.issues


def test_copy_follows_the_blueprint_copy_role():
    plans = _plans()
    plans["plans"][1]["copy"] = None
    _, report = _check(plans)
    assert "plans.1.copy: write the slide text for this plan" in report.issues

    no_text = _blueprint()
    no_text["copyStrategy"]["role"] = "none"
    _, report = _check(_plans(), blueprint=no_text)
    assert "plans.0.copy: the blueprint has no copy role, so use null" in report.issues


@pytest.mark.parametrize(
    ("text", "issue"),
    [
        ("x" * 151, "at most 150 characters"),
        ("Line one\nline two", "plans.0.copy.text: keep it to one line"),
        ("One. Two. Three. Four.", "plans.0.copy.text: at most 3 sentences"),
    ],
)
def test_hook_text_rules(text, issue):
    plans = _plans()
    plans["plans"][0]["copy"]["text"] = text
    _, report = _check(plans)
    assert not report.passed
    assert any(issue in i for i in report.issues), report.issues


def test_near_duplicate_plans_fail():
    reply = _ai_reply()
    reply["plans"][1] = copy.deepcopy(reply["plans"][0])
    reply["plans"][1]["title"] = "Another title"
    reply["plans"][1]["copy"]["text"] += "!"
    _, report = _check(_plans(reply))
    assert "plans.1: too close to plans.0" in report.issues


def test_plans_for_an_earlier_blueprint_or_analysis_fail():
    _, report = _check(_plans(), source="user", version=VERSION + 1)
    assert report.issues == ("blueprintVersion: written for an earlier blueprint; plan again",)

    _, report = _check(_plans(), source="user", run_id="run2")
    assert report.issues == ("analysisRunId: written for an earlier analysis; plan again",)


def test_duplicate_ids_and_unknown_fields_fail():
    plans = _plans()
    plans["plans"][1]["id"] = "p1"
    _, report = _check(plans, source="user")
    assert "plans.1.id: 'p1' is used twice" in report.issues

    plans = _plans()
    plans["plans"][0]["strength"] = "high"
    _, report = _check(plans)
    assert any("strength" in issue for issue in report.issues)


def test_plan_sends_blueprint_analysis_and_count_and_retries_with_feedback():
    bad = _ai_reply()
    bad["plans"] = bad["plans"][:1]
    model = ScriptedModel(
        ModelReply(json.dumps(bad), "m"), ModelReply(json.dumps(_ai_reply()), "m")
    )

    outcome = plan(_blueprint(), VERSION, _sample(), RUN_ID, 2, b"webp", model)

    assert outcome.passed
    assert [a.report.status for a in outcome.attempts] == ["failed", "passed"]
    assert outcome.result["plans"][0]["copy"]["pattern"] == "POV"
    assert outcome.result["blueprintVersion"] == VERSION
    assert model.instructions[0] == INSTRUCTIONS
    assert model.instructions[1] == build_instructions(outcome.attempts[0].report.issues)
    assert model.user_texts[0].startswith("Write exactly 2 variation plans.")
    assert '"creativeFamily": "ugc_car_selfie_hook"' in model.user_texts[0]
    assert '"creativeType": "ugc_hook_slide"' in model.user_texts[0]
