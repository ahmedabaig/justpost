from __future__ import annotations

import json
from datetime import datetime, timezone
import os
from io import BytesIO
from types import SimpleNamespace

import pytest
from google.api_core.exceptions import AlreadyExists
from PIL import Image

os.environ.setdefault("GCLOUD_PROJECT", "justpost-test")

import main  # noqa: E402
from firebase_functions import https_fn  # noqa: E402
from justpost.model_io import ImageReply, ModelError, ModelReply  # noqa: E402
from test_analysis import ScriptedModel, _sample  # noqa: E402
from test_blueprint import _ai_reply, _draft  # noqa: E402
from test_generation import ScriptedImageModel, _png  # noqa: E402
from test_planning import _ai_reply as _plan_reply  # noqa: E402
from test_planning import _plans as _confirmed_plans  # noqa: E402
from test_validation import FACE as _FACE  # noqa: E402
from test_validation import _answers as _check_answers  # noqa: E402

UID = "user-1"
ASSET_ID = "abcdefghij0123456789"
FOLDER = f"uploads/{UID}/{ASSET_ID}/"
Code = https_fn.FunctionsErrorCode


def _jpeg(width: int = 60, height: int = 120) -> bytes:
    buffer = BytesIO()
    Image.new("RGB", (width, height), "teal").save(buffer, "JPEG")
    return buffer.getvalue()


class FakeBlob:
    def __init__(self, name: str, data: bytes = b"", size: int | None = None):
        self.name = name
        self.data = data
        self.size = len(data) if size is None else size
        self.content_type = None

    def download_as_bytes(self) -> bytes:
        return self.data

    def upload_from_string(self, data: bytes, content_type: str) -> None:
        self.data = data
        self.size = len(data)
        self.content_type = content_type


class FakeBucket:
    def __init__(self, blobs: list[FakeBlob], fail_uploads: bool = False):
        self.blobs = {blob.name: blob for blob in blobs}
        self.fail_uploads = fail_uploads

    def list_blobs(self, prefix: str):
        return [blob for name, blob in self.blobs.items() if name.startswith(prefix)]

    def blob(self, name: str) -> FakeBlob:
        if self.fail_uploads:
            raise RuntimeError("storage unavailable")
        return self.blobs.setdefault(name, FakeBlob(name))


class FakeDocRef:
    def __init__(self, doc_id: str):
        self.id = doc_id
        self.data: dict | None = None
        self.subcollections: dict[str, FakeCollection] = {}

    def create(self, data: dict) -> None:
        if self.data is not None:
            raise AlreadyExists("exists")
        self.data = dict(data)

    def set(self, data: dict) -> None:
        self.data = dict(data)

    def update(self, data: dict) -> None:
        """Like Firestore, a dotted key updates one field inside a map."""
        assert self.data is not None
        for key, value in data.items():
            *parents, leaf = key.split(".")
            target = self.data
            for parent in parents:
                target = target.setdefault(parent, {})
            target[leaf] = value

    def get(self):
        data = self.data
        return SimpleNamespace(
            exists=data is not None, to_dict=lambda: dict(data) if data else None
        )

    def collection(self, name: str) -> FakeCollection:
        return self.subcollections.setdefault(name, FakeCollection())


class FakeQuery:
    """Equality filters, one descending order and a limit, as the Library uses."""

    def __init__(self, docs, filters=(), order=None, limit=None):
        self._docs, self._filters, self._order, self._limit = docs, filters, order, limit

    def where(self, filter):
        assert filter.op_string == "=="
        return FakeQuery(self._docs, (*self._filters, filter), self._order, self._limit)

    def order_by(self, field, direction):
        assert direction == "DESCENDING"
        return FakeQuery(self._docs, self._filters, field, self._limit)

    def limit(self, count):
        return FakeQuery(self._docs, self._filters, self._order, count)

    def stream(self):
        docs = [
            doc
            for doc in self._docs.values()
            if doc.data is not None
            and all(doc.data.get(f.field_path) == f.value for f in self._filters)
        ]
        if self._order:
            docs.sort(key=lambda doc: doc.data.get(self._order), reverse=True)
        for doc in docs[: self._limit]:
            yield SimpleNamespace(id=doc.id, to_dict=lambda data=doc.data: dict(data))


class FakeCollection:
    def __init__(self):
        self.docs: dict[str, FakeDocRef] = {}

    def document(self, doc_id: str | None = None) -> FakeDocRef:
        doc_id = doc_id or f"run{len(self.docs) + 1}"
        return self.docs.setdefault(doc_id, FakeDocRef(doc_id))

    def where(self, filter):
        return FakeQuery(self.docs).where(filter)


class FakeDB:
    def __init__(self):
        self.collections: dict[str, FakeCollection] = {}

    @property
    def docs(self) -> dict[str, FakeDocRef]:
        return self.collection("assets").docs

    def collection(self, name: str) -> FakeCollection:
        return self.collections.setdefault(name, FakeCollection())


def _bucket_with(*blobs: FakeBlob, **kwargs) -> FakeBucket:
    return FakeBucket(list(blobs), **kwargs)


def _run(bucket, db, asset_id=ASSET_ID):
    return main.run_ingest(uid=UID, asset_id=asset_id, bucket=bucket, db=db)


def test_ingests_the_original_and_records_the_asset():
    bucket = _bucket_with(FakeBlob(f"{FOLDER}original.jpg", _jpeg()))
    db = FakeDB()

    result = _run(bucket, db)

    assert result["status"] == "ready"
    assert result["assetId"] == ASSET_ID
    assert (result["width"], result["height"]) == (60, 120)
    assert result["orientation"] == "portrait"
    assert bucket.blobs[f"{FOLDER}working.png"].content_type == "image/png"
    assert bucket.blobs[f"{FOLDER}analysis.webp"].content_type == "image/webp"
    record = db.docs[ASSET_ID].data
    assert record["uid"] == UID
    assert record["status"] == "ready"
    assert record["originalPath"] == f"{FOLDER}original.jpg"
    assert record["workingPath"] == f"{FOLDER}working.png"


def test_only_reads_the_callers_own_folder():
    other = FakeBlob(f"uploads/someone-else/{ASSET_ID}/original.jpg", _jpeg())
    with pytest.raises(https_fn.HttpsError) as error:
        _run(_bucket_with(other), FakeDB())
    assert error.value.code == Code.FAILED_PRECONDITION


@pytest.mark.parametrize(
    "asset_id", [None, 42, "short", "../../../etc/passwd00", "abcdefghij012345678!"]
)
def test_rejects_malformed_asset_ids(asset_id):
    with pytest.raises(https_fn.HttpsError) as error:
        _run(_bucket_with(), FakeDB(), asset_id=asset_id)
    assert error.value.code == Code.INVALID_ARGUMENT


def test_requires_an_uploaded_original():
    with pytest.raises(https_fn.HttpsError) as error:
        _run(_bucket_with(), FakeDB())
    assert error.value.code == Code.FAILED_PRECONDITION


def test_rejects_more_than_one_original():
    bucket = _bucket_with(
        FakeBlob(f"{FOLDER}original.jpg", _jpeg()),
        FakeBlob(f"{FOLDER}original.png", _jpeg()),
    )
    with pytest.raises(https_fn.HttpsError) as error:
        _run(bucket, FakeDB())
    assert error.value.code == Code.FAILED_PRECONDITION


def test_rejects_oversized_uploads():
    blob = FakeBlob(f"{FOLDER}original.jpg", _jpeg(), size=main.MAX_UPLOAD_BYTES + 1)
    with pytest.raises(https_fn.HttpsError) as error:
        _run(_bucket_with(blob), FakeDB())
    assert error.value.code == Code.INVALID_ARGUMENT


def test_an_asset_is_ingested_only_once():
    bucket = _bucket_with(FakeBlob(f"{FOLDER}original.jpg", _jpeg()))
    db = FakeDB()
    _run(bucket, db)
    with pytest.raises(https_fn.HttpsError) as error:
        _run(bucket, db)
    assert error.value.code == Code.ALREADY_EXISTS


def test_unreadable_images_are_recorded_as_failed():
    bucket = _bucket_with(FakeBlob(f"{FOLDER}original.jpg", b"not an image"))
    db = FakeDB()

    with pytest.raises(https_fn.HttpsError) as error:
        _run(bucket, db)

    assert error.value.code == Code.INVALID_ARGUMENT
    assert db.docs[ASSET_ID].data["status"] == "failed"
    assert f"{FOLDER}working.png" not in bucket.blobs


def test_unexpected_errors_are_recorded_without_details():
    bucket = _bucket_with(
        FakeBlob(f"{FOLDER}original.jpg", _jpeg()), fail_uploads=True
    )
    db = FakeDB()

    with pytest.raises(https_fn.HttpsError) as error:
        _run(bucket, db)

    assert error.value.code == Code.INTERNAL
    record = db.docs[ASSET_ID].data
    assert record["status"] == "failed"
    assert "storage unavailable" not in record["error"]


# analyze_asset


def _ready_asset(db: FakeDB, uid: str = UID, status: str = "ready") -> FakeBucket:
    """Records an ingested asset the way run_ingest leaves it."""
    db.docs[ASSET_ID] = FakeDocRef(ASSET_ID)
    db.docs[ASSET_ID].data = {
        "uid": uid,
        "status": status,
        "analysisPath": f"uploads/{uid}/{ASSET_ID}/analysis.webp",
        "orientation": "portrait",
    }
    return _bucket_with(FakeBlob(f"uploads/{uid}/{ASSET_ID}/analysis.webp", b"webp"))


def _analyze(bucket, db, model, expose_raw=True, slots=None, asset_id=ASSET_ID):
    taken = [] if slots is None else slots

    def take_slot(_db, uid):
        taken.append(uid)
        return len(taken) <= 2

    return main.run_analyze(
        uid=UID,
        asset_id=asset_id,
        bucket=bucket,
        db=db,
        model=model,
        expose_raw=expose_raw,
        take_slot=take_slot,
    )


def _good_reply():
    return ModelReply(text=json.dumps(_sample()), model="test-model")


def test_analysis_that_passes_is_saved_with_its_run():
    db = FakeDB()
    bucket = _ready_asset(db)

    result = _analyze(bucket, db, ScriptedModel(_good_reply()))

    assert result["status"] == "passed"
    assert result["analysis"]["creativeType"] == "ugc_hook_slide"
    assert result["attempts"][0]["rawText"] == json.dumps(_sample())
    asset = db.docs[ASSET_ID]
    assert asset.data["analysisStatus"] == "ready"
    assert asset.data["analysis"] == result["analysis"]
    run = asset.subcollections["analysisRuns"].docs[result["runId"]].data
    assert asset.data["analysisRunId"] == result["runId"]
    assert run["uid"] == UID
    assert run["status"] == "passed"
    assert run["attempts"][0]["status"] == "passed"


def test_nothing_is_saved_as_the_analysis_when_every_attempt_fails():
    db = FakeDB()
    bucket = _ready_asset(db)
    model = ScriptedModel(
        ModelReply(text="Sure thing!", model="m"),
        ModelReply(text="{}", model="m"),
    )

    result = _analyze(bucket, db, model)

    assert result["status"] == "failed"
    assert result["analysis"] is None
    assert [a["status"] for a in result["attempts"]] == ["failed", "failed"]
    asset = db.docs[ASSET_ID].data
    assert asset["analysisStatus"] == "failed"
    assert asset["analysis"] is None
    run = db.docs[ASSET_ID].subcollections["analysisRuns"].docs[result["runId"]]
    assert run.data["attempts"][0]["rawText"] == "Sure thing!"


def test_a_failed_rerun_clears_the_earlier_analysis():
    db = FakeDB()
    bucket = _ready_asset(db)
    _analyze(bucket, db, ScriptedModel(_good_reply()), slots=[])
    _analyze(
        bucket,
        db,
        ScriptedModel(ModelReply("x", "m"), ModelReply("y", "m")),
        slots=[],
    )
    asset = db.docs[ASSET_ID].data
    assert asset["analysisStatus"] == "failed"
    assert asset["analysis"] is None
    assert len(db.docs[ASSET_ID].subcollections["analysisRuns"].docs) == 2


def test_raw_text_is_left_out_of_the_reply_when_exposure_is_off():
    db = FakeDB()
    bucket = _ready_asset(db)

    result = _analyze(bucket, db, ScriptedModel(_good_reply()), expose_raw=False)

    assert result["rawExposed"] is False
    assert "rawText" not in result["attempts"][0]
    assert result["attempts"][0]["status"] == "passed"
    assert result["analysis"] is not None


def test_someone_elses_asset_is_reported_as_missing():
    db = FakeDB()
    bucket = _ready_asset(db, uid="someone-else")
    with pytest.raises(https_fn.HttpsError) as error:
        _analyze(bucket, db, ScriptedModel())
    assert error.value.code == Code.NOT_FOUND


def test_a_missing_asset_is_reported_as_missing():
    with pytest.raises(https_fn.HttpsError) as error:
        _analyze(_bucket_with(), FakeDB(), ScriptedModel())
    assert error.value.code == Code.NOT_FOUND


@pytest.mark.parametrize("asset_id", [None, "short", "../../etc/passwd000000"])
def test_analyze_rejects_malformed_asset_ids(asset_id):
    with pytest.raises(https_fn.HttpsError) as error:
        _analyze(_bucket_with(), FakeDB(), ScriptedModel(), asset_id=asset_id)
    assert error.value.code == Code.INVALID_ARGUMENT


def test_an_asset_that_is_not_ready_cannot_be_analyzed():
    db = FakeDB()
    bucket = _ready_asset(db, status="processing")
    slots: list[str] = []
    with pytest.raises(https_fn.HttpsError) as error:
        _analyze(bucket, db, ScriptedModel(), slots=slots)
    assert error.value.code == Code.FAILED_PRECONDITION
    assert slots == []


def test_the_daily_limit_stops_the_model_from_being_called():
    db = FakeDB()
    bucket = _ready_asset(db)
    model = ScriptedModel()
    with pytest.raises(https_fn.HttpsError) as error:
        _analyze(bucket, db, model, slots=[UID, UID])
    assert error.value.code == Code.RESOURCE_EXHAUSTED
    assert model.instructions == []


def test_unexpected_analysis_errors_are_generic():
    db = FakeDB()
    _ready_asset(db)

    class BrokenBucket(FakeBucket):
        def blob(self, name):
            raise RuntimeError("secret bucket detail")

    with pytest.raises(https_fn.HttpsError) as error:
        _analyze(BrokenBucket([]), db, ScriptedModel())
    assert error.value.code == Code.INTERNAL
    assert "secret" not in error.value.message


# build_blueprint and save_blueprint

ANALYSIS_RUN = "run1"


def _analyzed_asset(db: FakeDB, uid: str = UID, **fields) -> FakeBucket:
    """An asset after a passing analysis, the way run_analyze leaves it."""
    bucket = _ready_asset(db, uid=uid)
    db.docs[ASSET_ID].data.update(
        {
            "analysis": _sample(),
            "analysisStatus": "ready",
            "analysisRunId": ANALYSIS_RUN,
            **fields,
        }
    )
    return bucket


def _build(bucket, db, model, expose_raw=True, slots=None):
    taken = [] if slots is None else slots

    def take_slot(_db, uid):
        taken.append(uid)
        return len(taken) <= 2

    return main.run_build_blueprint(
        uid=UID,
        asset_id=ASSET_ID,
        bucket=bucket,
        db=db,
        model=model,
        expose_raw=expose_raw,
        take_slot=take_slot,
    )


def _draft_reply():
    return ModelReply(text=json.dumps(_ai_reply()), model="test-model")


def _saved_draft(db) -> dict:
    db_draft = db.docs[ASSET_ID].data["blueprintDraft"]
    return json.loads(json.dumps(db_draft))


def test_a_passing_blueprint_is_saved_as_the_draft():
    db = FakeDB()
    bucket = _analyzed_asset(db)

    result = _build(bucket, db, ScriptedModel(_draft_reply()))

    assert result["status"] == "passed"
    assert result["analysisRunId"] == ANALYSIS_RUN
    assert result["confirmed"] is None
    assert result["draft"]["requiredPrinciples"][0]["id"] == "req1"
    asset = db.docs[ASSET_ID]
    assert asset.data["blueprintDraftStatus"] == "ready"
    assert asset.data["blueprintDraft"] == result["draft"]
    assert "blueprint" not in asset.data
    run = asset.subcollections["blueprintRuns"].docs[result["runId"]].data
    assert run["analysisRunId"] == ANALYSIS_RUN
    assert run["attempts"][0]["rawText"] == json.dumps(_ai_reply())


def test_a_failed_build_clears_the_draft_but_keeps_the_confirmed_blueprint():
    db = FakeDB()
    bucket = _analyzed_asset(db, blueprint={"kept": True}, blueprintVersion=3)
    _build(bucket, db, ScriptedModel(_draft_reply()), slots=[])

    result = _build(
        bucket, db, ScriptedModel(ModelReply("no", "m"), ModelReply("{}", "m")), slots=[]
    )

    assert result["status"] == "failed"
    assert result["draft"] is None
    assert result["confirmed"] == {"blueprint": {"kept": True}, "version": 3}
    asset = db.docs[ASSET_ID].data
    assert asset["blueprintDraftStatus"] == "failed"
    assert asset["blueprintDraft"] is None
    assert asset["blueprint"] == {"kept": True}


def test_a_blueprint_needs_a_passing_analysis():
    db = FakeDB()
    bucket = _analyzed_asset(db, analysisStatus="failed", analysis=None)
    slots: list[str] = []
    with pytest.raises(https_fn.HttpsError) as error:
        _build(bucket, db, ScriptedModel(), slots=slots)
    assert error.value.code == Code.FAILED_PRECONDITION
    assert slots == []


def test_someone_elses_asset_cannot_get_a_blueprint():
    db = FakeDB()
    bucket = _analyzed_asset(db, uid="someone-else")
    with pytest.raises(https_fn.HttpsError) as error:
        _build(bucket, db, ScriptedModel())
    assert error.value.code == Code.NOT_FOUND


def test_the_blueprint_limit_stops_the_model_from_being_called():
    db = FakeDB()
    bucket = _analyzed_asset(db)
    model = ScriptedModel()
    with pytest.raises(https_fn.HttpsError) as error:
        _build(bucket, db, model, slots=[UID, UID])
    assert error.value.code == Code.RESOURCE_EXHAUSTED
    assert "blueprint limit" in error.value.message
    assert model.instructions == []


def test_raw_blueprint_text_is_left_out_when_exposure_is_off():
    db = FakeDB()
    bucket = _analyzed_asset(db)
    result = _build(bucket, db, ScriptedModel(_draft_reply()), expose_raw=False)
    assert "rawText" not in result["attempts"][0]
    assert result["draft"] is not None


def _save(db, edited, uid=UID):
    return main.run_save_blueprint(uid=uid, asset_id=ASSET_ID, edited=edited, db=db)


def test_saving_an_edited_draft_confirms_it_and_bumps_the_version():
    db = FakeDB()
    bucket = _analyzed_asset(db)
    _build(bucket, db, ScriptedModel(_draft_reply()))
    edited = _saved_draft(db)
    moved = edited["requiredPrinciples"].pop(1)
    edited["variationDimensions"].append(
        {"id": moved["id"], "name": moved["text"], "examples": [], "basis": moved["basis"], "origin": "user"}
    )
    edited["forbiddenDrift"] = []

    first = _save(db, edited)
    second = _save(db, edited)

    assert (first["version"], second["version"]) == (1, 2)
    asset = db.docs[ASSET_ID].data
    assert asset["blueprintVersion"] == 2
    assert asset["blueprint"]["forbiddenDrift"] == []
    assert asset["blueprint"]["variationDimensions"][-1]["origin"] == "user"


def test_an_invalid_edit_is_rejected_with_the_reasons():
    db = FakeDB()
    bucket = _analyzed_asset(db)
    _build(bucket, db, ScriptedModel(_draft_reply()))
    edited = _saved_draft(db)
    edited["requiredPrinciples"] = []

    with pytest.raises(https_fn.HttpsError) as error:
        _save(db, edited)

    assert error.value.code == Code.INVALID_ARGUMENT
    assert "requiredPrinciples: needs at least 1" in error.value.message
    assert "blueprint" not in db.docs[ASSET_ID].data


def test_a_draft_from_an_earlier_analysis_cannot_be_saved():
    db = FakeDB()
    bucket = _analyzed_asset(db)
    _build(bucket, db, ScriptedModel(_draft_reply()))
    edited = _saved_draft(db)
    db.docs[ASSET_ID].data["analysisRunId"] = "run2"

    with pytest.raises(https_fn.HttpsError) as error:
        _save(db, edited)

    assert error.value.code == Code.FAILED_PRECONDITION
    assert "Rebuild the draft" in error.value.message


def test_someone_elses_blueprint_cannot_be_saved():
    db = FakeDB()
    _analyzed_asset(db, uid="someone-else")
    with pytest.raises(https_fn.HttpsError) as error:
        _save(db, {})
    assert error.value.code == Code.NOT_FOUND


def test_saving_needs_a_blueprint_object():
    db = FakeDB()
    _analyzed_asset(db)
    with pytest.raises(https_fn.HttpsError) as error:
        _save(db, ["not", "a", "blueprint"])
    assert error.value.code == Code.INVALID_ARGUMENT


# plan_variations and save_plans


def _blueprinted_asset(db: FakeDB, uid: str = UID, **fields) -> FakeBucket:
    """An asset with a confirmed blueprint, the way run_save_blueprint leaves it."""
    return _analyzed_asset(
        db, uid=uid, blueprint=_draft(), blueprintVersion=2, **fields
    )


def _plan(bucket, db, model, count=2, expose_raw=True, slots=None, uid=UID):
    taken = [] if slots is None else slots

    def take_slot(_db, slot_uid):
        taken.append(slot_uid)
        return len(taken) <= 2

    return main.run_plan_variations(
        uid=uid,
        asset_id=ASSET_ID,
        count=count,
        bucket=bucket,
        db=db,
        model=model,
        expose_raw=expose_raw,
        take_slot=take_slot,
    )


def _plans_reply():
    return ModelReply(text=json.dumps(_plan_reply()), model="test-model")


def _saved_plans_draft(db) -> dict:
    return json.loads(json.dumps(db.docs[ASSET_ID].data["plansDraft"]))


def test_passing_plans_are_saved_as_the_draft():
    db = FakeDB()
    bucket = _blueprinted_asset(db)

    result = _plan(bucket, db, ScriptedModel(_plans_reply()))

    assert result["status"] == "passed"
    assert result["blueprintVersion"] == 2
    assert result["confirmed"] is None
    assert [p["id"] for p in result["draft"]["plans"]] == ["p1", "p2"]
    asset = db.docs[ASSET_ID]
    assert asset.data["plansDraftStatus"] == "ready"
    assert asset.data["plansDraft"] == result["draft"]
    assert "plans" not in asset.data
    run = asset.subcollections["planRuns"].docs[result["runId"]].data
    assert (run["blueprintVersion"], run["count"]) == (2, 2)
    assert run["attempts"][0]["rawText"] == json.dumps(_plan_reply())


def test_a_failed_plan_run_clears_the_draft_but_keeps_the_confirmed_plans():
    db = FakeDB()
    bucket = _blueprinted_asset(db, plans={"kept": True}, plansVersion=4)

    result = _plan(
        bucket, db, ScriptedModel(ModelReply("no", "m"), ModelReply("{}", "m"))
    )

    assert result["status"] == "failed"
    assert result["draft"] is None
    assert result["confirmed"] == {"plans": {"kept": True}, "version": 4}
    assert db.docs[ASSET_ID].data["plansDraft"] is None
    assert db.docs[ASSET_ID].data["plans"] == {"kept": True}


@pytest.mark.parametrize("count", [0, 6, "3", 2.5, True])
def test_the_plan_count_must_be_one_to_five(count):
    db = FakeDB()
    bucket = _blueprinted_asset(db)
    slots: list[str] = []
    with pytest.raises(https_fn.HttpsError) as error:
        _plan(bucket, db, ScriptedModel(), count=count, slots=slots)
    assert error.value.code == Code.INVALID_ARGUMENT
    assert slots == []


def test_the_plan_count_defaults_to_one():
    db = FakeDB()
    bucket = _blueprinted_asset(db)
    reply = _plan_reply()
    reply["plans"] = reply["plans"][:1]
    model = ScriptedModel(ModelReply(json.dumps(reply), "m"))

    result = _plan(bucket, db, model, count=None)

    assert result["count"] == 1
    assert result["status"] == "passed"
    assert model.user_texts[0].startswith("Write exactly 1 variation plan.")


def test_planning_needs_a_confirmed_blueprint_for_the_current_analysis():
    db = FakeDB()
    bucket = _analyzed_asset(db)
    with pytest.raises(https_fn.HttpsError) as error:
        _plan(bucket, db, ScriptedModel())
    assert error.value.code == Code.FAILED_PRECONDITION
    assert "Save the blueprint first" in error.value.message

    db = FakeDB()
    bucket = _blueprinted_asset(db, analysisRunId="run2")
    with pytest.raises(https_fn.HttpsError) as error:
        _plan(bucket, db, ScriptedModel())
    assert error.value.code == Code.FAILED_PRECONDITION
    assert "analysis changed" in error.value.message


def test_someone_elses_asset_cannot_be_planned():
    db = FakeDB()
    bucket = _blueprinted_asset(db, uid="someone-else")
    with pytest.raises(https_fn.HttpsError) as error:
        _plan(bucket, db, ScriptedModel())
    assert error.value.code == Code.NOT_FOUND


def test_the_planning_limit_stops_the_model_from_being_called():
    db = FakeDB()
    bucket = _blueprinted_asset(db)
    model = ScriptedModel()
    with pytest.raises(https_fn.HttpsError) as error:
        _plan(bucket, db, model, slots=[UID, UID])
    assert error.value.code == Code.RESOURCE_EXHAUSTED
    assert "planning limit" in error.value.message
    assert model.instructions == []


def test_raw_plan_text_is_left_out_when_exposure_is_off():
    db = FakeDB()
    bucket = _blueprinted_asset(db)
    result = _plan(bucket, db, ScriptedModel(_plans_reply()), expose_raw=False)
    assert "rawText" not in result["attempts"][0]
    assert result["draft"] is not None


def _save_plans(db, edited, uid=UID):
    return main.run_save_plans(uid=uid, asset_id=ASSET_ID, edited=edited, db=db)


def test_saving_edited_plans_confirms_them_and_bumps_the_version():
    db = FakeDB()
    bucket = _blueprinted_asset(db)
    _plan(bucket, db, ScriptedModel(_plans_reply()))
    edited = _saved_plans_draft(db)
    edited["plans"][0]["changes"] = [{"dimensionId": "var3", "value": "gold star"}]
    edited["plans"].append(
        {
            "id": "u1",
            "origin": "user",
            "title": "My own idea",
            "changes": [
                {"dimensionId": "var1", "value": "navy"},
                {"dimensionId": "var2", "value": "hot chocolate"},
                {"dimensionId": "var3", "value": "crescent moon"},
            ],
            "copy": {"text": "Your phone can remind you of Allah's Names", "pattern": "statement"},
        }
    )

    first = _save_plans(db, edited)
    second = _save_plans(db, edited)

    assert (first["version"], second["version"]) == (1, 2)
    asset = db.docs[ASSET_ID].data
    assert asset["plansVersion"] == 2
    assert asset["plans"]["plans"][-1]["origin"] == "user"
    assert "copy" in asset["plans"]["plans"][0]


def test_invalid_plan_edits_are_rejected_with_the_reasons():
    db = FakeDB()
    bucket = _blueprinted_asset(db)
    _plan(bucket, db, ScriptedModel(_plans_reply()))
    edited = _saved_plans_draft(db)
    edited["plans"][0]["changes"][0]["dimensionId"] = "req1"

    with pytest.raises(https_fn.HttpsError) as error:
        _save_plans(db, edited)

    assert error.value.code == Code.INVALID_ARGUMENT
    assert "'req1' is not a 'can vary' dimension" in error.value.message
    assert "plans" not in db.docs[ASSET_ID].data


def test_plans_for_an_earlier_blueprint_cannot_be_saved():
    db = FakeDB()
    bucket = _blueprinted_asset(db)
    _plan(bucket, db, ScriptedModel(_plans_reply()))
    edited = _saved_plans_draft(db)
    db.docs[ASSET_ID].data["blueprintVersion"] = 3

    with pytest.raises(https_fn.HttpsError) as error:
        _save_plans(db, edited)

    assert error.value.code == Code.FAILED_PRECONDITION
    assert "Plan again" in error.value.message


def test_someone_elses_plans_cannot_be_saved():
    db = FakeDB()
    _blueprinted_asset(db, uid="someone-else")
    with pytest.raises(https_fn.HttpsError) as error:
        _save_plans(db, {})
    assert error.value.code == Code.NOT_FOUND


def test_saving_needs_a_plans_object():
    db = FakeDB()
    _blueprinted_asset(db)
    with pytest.raises(https_fn.HttpsError) as error:
        _save_plans(db, ["not", "plans"])
    assert error.value.code == Code.INVALID_ARGUMENT


# generate_variation


def _planned_asset(db: FakeDB, uid: str = UID, **fields) -> FakeBucket:
    """An asset with confirmed plans, the way run_save_plans leaves it."""
    return _blueprinted_asset(
        db,
        uid=uid,
        width=1179,
        height=2556,
        plans=_confirmed_plans(),
        plansVersion=3,
        **fields,
    )


def _check(overrides=None, **kwargs) -> ModelReply:
    return ModelReply(
        json.dumps(_check_answers(overrides, **kwargs)),
        "gpt-check-test",
        input_tokens=300,
        output_tokens=80,
    )


def _generate(bucket, db, model, plan_id="p1", expose=True, slots=None, uid=UID, checker=None):
    taken = [] if slots is None else slots

    def take_slot(_db, slot_uid):
        taken.append(slot_uid)
        return len(taken) <= 2

    return main.run_generate_variation(
        uid=uid,
        asset_id=ASSET_ID,
        plan_id=plan_id,
        bucket=bucket,
        db=db,
        model=model,
        checker=checker or ScriptedModel(_check()),
        quality="medium",
        expose_images=expose,
        take_slot=take_slot,
    )


def _image_reply(size=(704, 1536)):
    return ImageReply(_png(size=size), "gpt-image-test", 100, 200)


def test_a_passing_image_is_checked_and_stored():
    db = FakeDB()
    bucket = _planned_asset(db)
    model = ScriptedImageModel(_image_reply())
    checker = ScriptedModel(_check())

    result = _generate(bucket, db, model, checker=checker)

    path = f"{FOLDER}variations/{result['runId']}.png"
    assert result["status"] == "passed"
    assert result["issues"] == []
    assert result["imagePath"] == path
    assert (result["width"], result["height"]) == (704, 1536)
    assert result["plansVersion"] == 3
    assert bucket.blobs[path].content_type == "image/png"
    assert model.calls[0][1:] == (b"webp", "704x1536")
    assert checker.images[0][0] == b"webp"
    assert {check["id"] for check in result["checks"]} >= {"required:req1", "change:1"}

    run = db.docs[ASSET_ID].subcollections["generationRuns"].docs[result["runId"]].data
    assert (run["status"], run["planId"], run["size"]) == ("passed", "p1", "704x1536")
    assert (run["blueprintVersion"], run["plansVersion"]) == (2, 3)
    assert run["request"] == model.calls[0][0]
    assert (run["model"], run["quality"]) == ("gpt-image-test", "medium")
    assert run["validation"]["model"] == "gpt-check-test"
    assert run["validation"]["keepClear"] == [_FACE]
    assert db.docs[ASSET_ID].data["variations"]["p1"] == {
        "runId": result["runId"],
        "status": "passed",
        "imagePath": path,
        "width": 704,
        "height": 1536,
        "plansVersion": 3,
    }


def test_a_passed_image_is_shown_without_inspection_but_without_model_notes():
    db = FakeDB()
    bucket = _planned_asset(db)
    result = _generate(bucket, db, ScriptedImageModel(_image_reply()), expose=False)
    assert result["status"] == "passed"
    assert result["imageExposed"] is True
    assert result["imagePath"] is not None
    assert all("note" not in check for check in result["checks"])


def test_a_rejected_image_gives_reasons_and_is_hidden_without_inspection():
    db = FakeDB()
    bucket = _planned_asset(db)
    checker = ScriptedModel(_check({"forbidden:never2": "yes"}))

    result = _generate(bucket, db, ScriptedImageModel(_image_reply()), expose=False, checker=checker)

    assert result["status"] == "rejected"
    assert result["issues"] == ["Not allowed: Showing the face clearly"]
    assert result["imageExposed"] is False
    assert result["imagePath"] is None
    run = db.docs[ASSET_ID].subcollections["generationRuns"].docs[result["runId"]].data
    assert run["imagePath"] is not None


def test_a_rejected_image_is_shown_for_inspection_with_notes():
    db = FakeDB()
    bucket = _planned_asset(db)
    checker = ScriptedModel(_check({"artifacts": "yes"}))
    result = _generate(bucket, db, ScriptedImageModel(_image_reply()), checker=checker)
    assert result["status"] == "rejected"
    assert result["imagePath"] is not None
    assert all("note" in check for check in result["checks"])


def test_an_image_that_cannot_be_checked_is_unverified():
    db = FakeDB()
    bucket = _planned_asset(db)
    checker = ScriptedModel(ModelError("down"), ModelError("down"))

    result = _generate(bucket, db, ScriptedImageModel(_image_reply()), expose=False, checker=checker)

    assert result["status"] == "unverified"
    assert result["issues"] == ["The image couldn't be checked."]
    assert result["imagePath"] is None
    assert result["checks"] == []


def test_a_failed_image_is_recorded_without_a_file_or_a_check():
    db = FakeDB()
    bucket = _planned_asset(db)
    checker = ScriptedModel()

    result = _generate(
        bucket, db, ScriptedImageModel(_image_reply(size=(1024, 1536))), checker=checker
    )

    assert result["status"] == "failed"
    assert result["imagePath"] is None
    assert result["issues"] == ["The image is 1024x1536, not the requested 704x1536."]
    assert not any("variations/" in name for name in bucket.blobs)
    assert db.docs[ASSET_ID].data["variations"]["p1"]["status"] == "failed"
    assert checker.instructions == []


def test_generation_needs_confirmed_plans():
    db = FakeDB()
    bucket = _blueprinted_asset(db, width=1179, height=2556)
    with pytest.raises(https_fn.HttpsError) as error:
        _generate(bucket, db, ScriptedImageModel())
    assert error.value.code == Code.FAILED_PRECONDITION
    assert "Save the plans first" in error.value.message


def test_plans_for_an_earlier_blueprint_are_refused_before_any_request():
    db = FakeDB()
    bucket = _planned_asset(db)
    db.docs[ASSET_ID].data["blueprintVersion"] = 3
    slots: list[str] = []
    model = ScriptedImageModel()

    with pytest.raises(https_fn.HttpsError) as error:
        _generate(bucket, db, model, slots=slots)

    assert error.value.code == Code.FAILED_PRECONDITION
    assert "Plan again" in error.value.message
    assert slots == []
    assert model.calls == []


@pytest.mark.parametrize("plan_id", [None, 3, "", "P1", "../p1", "x" * 41])
def test_malformed_plan_ids_are_rejected(plan_id):
    db = FakeDB()
    bucket = _planned_asset(db)
    with pytest.raises(https_fn.HttpsError) as error:
        _generate(bucket, db, ScriptedImageModel(), plan_id=plan_id)
    assert error.value.code == Code.INVALID_ARGUMENT


def test_an_unknown_plan_is_not_found():
    db = FakeDB()
    bucket = _planned_asset(db)
    with pytest.raises(https_fn.HttpsError) as error:
        _generate(bucket, db, ScriptedImageModel(), plan_id="p9")
    assert error.value.code == Code.NOT_FOUND


def test_someone_elses_plans_cannot_be_generated():
    db = FakeDB()
    bucket = _planned_asset(db, uid="someone-else")
    with pytest.raises(https_fn.HttpsError) as error:
        _generate(bucket, db, ScriptedImageModel())
    assert error.value.code == Code.NOT_FOUND


def test_the_image_limit_stops_the_model_from_being_called():
    db = FakeDB()
    bucket = _planned_asset(db)
    model = ScriptedImageModel()
    with pytest.raises(https_fn.HttpsError) as error:
        _generate(bucket, db, model, slots=[UID, UID])
    assert error.value.code == Code.RESOURCE_EXHAUSTED
    assert "image limit" in error.value.message
    assert model.calls == []


def test_unexpected_generation_errors_are_reported_without_details():
    db = FakeDB()
    bucket = _planned_asset(db)
    bucket.fail_uploads = True
    with pytest.raises(https_fn.HttpsError) as error:
        _generate(bucket, db, ScriptedImageModel(_image_reply()))
    assert error.value.code == Code.INTERNAL
    assert "storage unavailable" not in error.value.message


# render_slide

GEN_RUN = "GenRun00000000000001"


def _generated(db: FakeDB, uid: str = UID, keep_clear=(), **run_fields) -> FakeBucket:
    """An asset with a passed image for plan p1, as run_generate_variation leaves it."""
    bucket = _planned_asset(db, uid=uid)
    image_path = f"uploads/{uid}/{ASSET_ID}/variations/{GEN_RUN}.png"
    bucket.blobs[image_path] = FakeBlob(image_path, _png())
    run = db.docs[ASSET_ID].collection("generationRuns").document(GEN_RUN)
    run.data = {
        "uid": uid,
        "planId": "p1",
        "plansVersion": 3,
        "status": "passed",
        "imagePath": image_path,
        "validation": {"keepClear": list(keep_clear)},
        **run_fields,
    }
    return bucket


def _render(bucket, db, layout=None, run_id=GEN_RUN, expose=True, slots=None, uid=UID):
    taken = [] if slots is None else slots

    def take_slot(_db, slot_uid):
        taken.append(slot_uid)
        return len(taken) <= 2

    return main.run_render_slide(
        uid=uid,
        asset_id=ASSET_ID,
        run_id=run_id,
        layout=layout,
        bucket=bucket,
        db=db,
        expose_images=expose,
        take_slot=take_slot,
    )


def test_the_plan_text_is_drawn_and_stored_as_a_slide():
    db = FakeDB()
    bucket = _generated(db)

    result = _render(bucket, db)

    path = f"{FOLDER}slides/{result['renderId']}.png"
    assert result["status"] == "rendered"
    assert result["planId"] == "p1"
    assert result["imagePath"] == path
    assert result["hasText"] is True
    assert result["layout"]["style"] == "outlined"
    assert result["layout"]["position"] == "reference"
    assert " ".join(result["lines"]) == _confirmed_plans()["plans"][0]["copy"]["text"]
    assert bucket.blobs[path].content_type == "image/png"

    record = db.docs[ASSET_ID].subcollections["slideRenders"].docs[result["renderId"]].data
    assert (record["status"], record["generationRunId"], record["plansVersion"]) == (
        "rendered",
        GEN_RUN,
        3,
    )
    assert db.docs[ASSET_ID].data["slides"]["p1"]["imagePath"] == path


def test_a_chosen_style_and_position_are_used():
    db = FakeDB()
    bucket = _generated(db)
    result = _render(bucket, db, layout={"style": "dark_box", "position": "top"})
    assert result["layout"]["style"] == "dark_box"
    assert result["layout"]["box"] == {"x": 0.08, "y": 0.08, "w": 0.84, "h": 0.2}


@pytest.mark.parametrize(
    "layout",
    [
        {"style": "comic"},
        {"box": {"x": 0, "y": 0, "w": 1, "h": 1}},
        {"text": "Something else"},
        "outlined",
    ],
)
def test_bad_layouts_and_app_text_are_rejected(layout):
    db = FakeDB()
    bucket = _generated(db)
    slots: list[str] = []
    with pytest.raises(https_fn.HttpsError) as error:
        _render(bucket, db, layout=layout, slots=slots)
    assert error.value.code == Code.INVALID_ARGUMENT
    assert slots == []


def test_text_that_does_not_fit_is_recorded_and_keeps_the_last_slide():
    db = FakeDB()
    bucket = _generated(db)
    first = _render(bucket, db)
    db.docs[ASSET_ID].data["plans"]["plans"][0]["copy"]["text"] = " ".join(
        ["Supercalifragilisticexpialidocious"] * 4
    )

    result = _render(bucket, db)

    assert result["status"] == "failed"
    assert result["imagePath"] is None
    assert "doesn't fit" in result["issues"][0]
    assert db.docs[ASSET_ID].data["slides"]["p1"]["renderId"] == first["renderId"]


def test_characters_the_font_lacks_fail_with_a_reason():
    db = FakeDB()
    bucket = _generated(db)
    db.docs[ASSET_ID].data["plans"]["plans"][0]["copy"]["text"] = "Ready? 🙂"
    result = _render(bucket, db)
    assert result["status"] == "failed"
    assert result["issues"] == ["The font can't draw these characters: 🙂"]


def test_a_plan_without_text_gives_the_image_as_the_slide():
    db = FakeDB()
    bucket = _generated(db)
    db.docs[ASSET_ID].data["plans"]["plans"][0]["copy"] = None
    result = _render(bucket, db)
    assert result["status"] == "rendered"
    assert result["hasText"] is False
    assert result["lines"] == []


def test_slides_for_images_from_earlier_plans_are_refused():
    db = FakeDB()
    bucket = _generated(db, plansVersion=2)
    slots: list[str] = []
    with pytest.raises(https_fn.HttpsError) as error:
        _render(bucket, db, slots=slots)
    assert error.value.code == Code.FAILED_PRECONDITION
    assert "Create the images again" in error.value.message
    assert slots == []


@pytest.mark.parametrize(
    "run_fields",
    [
        {"status": "failed"},
        {"uid": "someone-else"},
        {"imagePath": "uploads/someone-else/elsewhere/variations/x.png"},
    ],
)
def test_only_the_owners_created_images_can_get_text(run_fields):
    db = FakeDB()
    bucket = _generated(db, **run_fields)
    with pytest.raises(https_fn.HttpsError) as error:
        _render(bucket, db)
    assert error.value.code == Code.NOT_FOUND


@pytest.mark.parametrize("run_id", [None, 7, "short", "GenRun0000000000000/", "Missing0000000000000"])
def test_malformed_or_unknown_run_ids_are_rejected(run_id):
    db = FakeDB()
    bucket = _generated(db)
    with pytest.raises(https_fn.HttpsError) as error:
        _render(bucket, db, run_id=run_id)
    assert error.value.code in (Code.INVALID_ARGUMENT, Code.NOT_FOUND)


def test_the_render_limit_applies():
    db = FakeDB()
    bucket = _generated(db)
    with pytest.raises(https_fn.HttpsError) as error:
        _render(bucket, db, slots=[UID, UID])
    assert error.value.code == Code.RESOURCE_EXHAUSTED


def test_slides_of_passed_images_are_shown_without_inspection():
    db = FakeDB()
    bucket = _generated(db)
    result = _render(bucket, db, expose=False)
    assert result["status"] == "rendered"
    assert result["imagePath"] is not None


@pytest.mark.parametrize("status", ["rejected", "unverified", "unchecked"])
def test_images_that_did_not_pass_get_text_only_for_inspection(status):
    db = FakeDB()
    bucket = _generated(db, status=status)
    slots: list[str] = []
    with pytest.raises(https_fn.HttpsError) as error:
        _render(bucket, db, expose=False, slots=slots)
    assert error.value.code == Code.FAILED_PRECONDITION
    assert slots == []

    assert _render(bucket, db, expose=True)["status"] == "rendered"


# Text fills the reference box (y 0.55-0.73) and bottom (0.62-0.82) on this asset.
_LOW_FACE = {"label": "face", "region": {"x": 0.3, "y": 0.62, "w": 0.4, "h": 0.1}}


def test_the_first_slide_moves_its_text_off_the_subject():
    db = FakeDB()
    bucket = _generated(db, keep_clear=[_LOW_FACE])

    result = _render(bucket, db)

    assert result["status"] == "rendered"
    assert result["layout"]["position"] == "top"
    record = db.docs[ASSET_ID].subcollections["slideRenders"].docs[result["renderId"]].data
    assert record["keepClear"] == [_LOW_FACE]
    assert record["textRegion"]["y"] < 0.3


def test_a_later_position_over_the_subject_is_refused_and_keeps_the_slide():
    db = FakeDB()
    bucket = _generated(db, keep_clear=[_LOW_FACE])
    first = _render(bucket, db)

    result = _render(bucket, db, layout={"position": "bottom"})

    assert result["status"] == "failed"
    assert result["issues"] == ["The text would cover the face. Try another position."]
    assert db.docs[ASSET_ID].data["slides"]["p1"]["renderId"] == first["renderId"]


def test_wrapped_64_bit_integers_from_mobile_sdks_are_decoded():
    wrapped = {"@type": "type.googleapis.com/google.protobuf.Int64Value", "value": "1"}
    req = SimpleNamespace(
        data={"blueprint": {"schemaVersion": wrapped, "items": [wrapped, "x"]}}
    )
    assert main._request_data(req) == {"blueprint": {"schemaVersion": 1, "items": [1, "x"]}}


def test_request_data_that_is_not_an_object_becomes_empty():
    assert main._request_data(SimpleNamespace(data=["not", "an", "object"])) == {}


def test_an_image_that_did_not_pass_leaves_no_path_on_the_asset():
    db = FakeDB()
    bucket = _planned_asset(db)
    checker = ScriptedModel(_check({"artifacts": "yes"}))
    result = _generate(bucket, db, ScriptedImageModel(_image_reply()), checker=checker)
    assert result["status"] == "rejected"
    assert db.docs[ASSET_ID].data["variations"]["p1"]["imagePath"] is None


# final set and Library

GEN_RUN_2 = "GenRun00000000000002"


def _with_slides(db: FakeDB, p2_status: str = "passed") -> FakeBucket:
    """Passed slides for p1 and a slide for p2 whose image has `p2_status`."""
    bucket = _generated(db, width=704, height=1536)
    _render(bucket, db)
    image_path = f"uploads/{UID}/{ASSET_ID}/variations/{GEN_RUN_2}.png"
    bucket.blobs[image_path] = FakeBlob(image_path, _png())
    run = db.docs[ASSET_ID].collection("generationRuns").document(GEN_RUN_2)
    run.data = {
        "uid": UID,
        "planId": "p2",
        "plansVersion": 3,
        "status": p2_status,
        "imagePath": image_path,
        "width": 704,
        "height": 1536,
    }
    _render(bucket, db, run_id=GEN_RUN_2)
    return bucket


def _save_set(db, plan_ids, uid=UID):
    return main.run_save_final_set(uid=uid, asset_id=ASSET_ID, plan_ids=plan_ids, db=db)


def test_a_final_set_keeps_the_chosen_order_and_slides():
    db = FakeDB()
    _with_slides(db)
    slides = db.docs[ASSET_ID].data["slides"]

    result = _save_set(db, ["p2", "p1"])

    saved = result["finalSet"]
    assert saved["version"] == 1
    assert [s["planId"] for s in saved["slides"]] == ["p2", "p1"]
    assert saved["slides"][0]["imagePath"] == slides["p2"]["imagePath"]
    assert saved["slides"][0]["generationRunId"] == GEN_RUN_2
    stored = db.docs[ASSET_ID].data
    assert stored["finalSetVersion"] == 1
    assert [s["renderId"] for s in stored["finalSet"]["slides"]] == [
        slides["p2"]["renderId"],
        slides["p1"]["renderId"],
    ]


def test_a_saved_set_is_a_snapshot_that_a_restyle_does_not_change():
    db = FakeDB()
    bucket = _with_slides(db)
    saved = _save_set(db, ["p1"])["finalSet"]["slides"][0]

    restyled = _render(bucket, db, layout={"style": "dark_box"})

    assert restyled["renderId"] != saved["renderId"]
    assert db.docs[ASSET_ID].data["finalSet"]["slides"][0]["renderId"] == saved["renderId"]
    assert _save_set(db, ["p1"])["finalSet"]["slides"][0]["renderId"] == restyled["renderId"]


@pytest.mark.parametrize("status", ["rejected", "unverified"])
def test_a_slide_whose_image_did_not_pass_cannot_join_the_set(status):
    db = FakeDB()
    _with_slides(db, p2_status=status)
    with pytest.raises(https_fn.HttpsError) as error:
        _save_set(db, ["p1", "p2"])
    assert error.value.code == Code.FAILED_PRECONDITION
    assert error.value.message == "Plan 2 has no slide that passed its checks."
    assert "finalSet" not in db.docs[ASSET_ID].data


def test_a_plan_without_a_slide_cannot_join_the_set():
    db = FakeDB()
    bucket = _generated(db)
    _render(bucket, db)
    with pytest.raises(https_fn.HttpsError) as error:
        _save_set(db, ["p2"])
    assert error.value.message == "Plan 2 has no slide that passed its checks."


def test_slides_from_earlier_plans_cannot_join_the_set():
    db = FakeDB()
    _with_slides(db)
    db.docs[ASSET_ID].data["plansVersion"] = 4
    with pytest.raises(https_fn.HttpsError) as error:
        _save_set(db, ["p1"])
    assert error.value.code == Code.FAILED_PRECONDITION


def test_a_set_needs_plans_for_the_current_blueprint():
    db = FakeDB()
    _with_slides(db)
    db.docs[ASSET_ID].data["blueprintVersion"] = 3
    with pytest.raises(https_fn.HttpsError) as error:
        _save_set(db, ["p1"])
    assert "Plan again" in error.value.message


@pytest.mark.parametrize("plan_ids", [[], ["p1", "p1"], "p1", [3], ["../p1"], ["p1"] * 6])
def test_malformed_set_requests_are_rejected(plan_ids):
    db = FakeDB()
    _with_slides(db)
    with pytest.raises(https_fn.HttpsError) as error:
        _save_set(db, plan_ids)
    assert error.value.code == Code.INVALID_ARGUMENT


def test_unknown_plans_and_other_peoples_sets_are_not_found():
    db = FakeDB()
    _with_slides(db)
    with pytest.raises(https_fn.HttpsError) as error:
        _save_set(db, ["p9"])
    assert error.value.code == Code.NOT_FOUND
    with pytest.raises(https_fn.HttpsError) as error:
        _save_set(db, ["p1"], uid="someone-else")
    assert error.value.code == Code.NOT_FOUND


def _library_asset(db, asset_id, uid=UID, updated=1, **fields):
    db.docs[asset_id] = FakeDocRef(asset_id)
    db.docs[asset_id].data = {
        "uid": uid,
        "status": "ready",
        "analysisPath": f"uploads/{uid}/{asset_id}/analysis.webp",
        "createdAt": datetime(2026, 10, 1, tzinfo=timezone.utc),
        "updatedAt": datetime(2026, 10, updated, tzinfo=timezone.utc),
        **fields,
    }


def test_the_library_lists_only_your_ready_references_newest_first():
    db = FakeDB()
    _library_asset(db, "older000000000000000", updated=2)
    _library_asset(db, "newer000000000000000", updated=5, analysisStatus="ready")
    _library_asset(db, "theirs00000000000000", uid="someone-else", updated=9)
    _library_asset(db, "failed00000000000000", updated=7, status="failed")

    result = main.run_list_slideshows(uid=UID, db=db)

    shows = result["slideshows"]
    assert [s["assetId"] for s in shows] == ["newer000000000000000", "older000000000000000"]
    assert shows[0]["stage"] == "analysis"
    assert shows[0]["updatedAt"] == "2026-10-05T00:00:00+00:00"
    assert shows[0]["referencePath"] == f"uploads/{UID}/newer000000000000000/analysis.webp"
    assert shows[1]["stage"] == "reference"


def test_the_library_is_capped(monkeypatch):
    monkeypatch.setattr(main, "LIBRARY_LIMIT", 2)
    db = FakeDB()
    for day in range(1, 5):
        _library_asset(db, f"asset{day}{'0' * 15}", updated=day)
    assert len(main.run_list_slideshows(uid=UID, db=db)["slideshows"]) == 2


def test_the_library_counts_passed_slides_and_the_saved_set():
    db = FakeDB()
    _with_slides(db)
    asset = db.docs[ASSET_ID].data
    asset["variations"] = {
        "p1": {"runId": GEN_RUN, "status": "passed", "plansVersion": 3},
        "p2": {"runId": GEN_RUN_2, "status": "rejected", "plansVersion": 3},
    }
    asset["updatedAt"] = datetime(2026, 10, 3, tzinfo=timezone.utc)
    summary = main.run_list_slideshows(uid=UID, db=db)["slideshows"][0]
    assert (summary["stage"], summary["passedSlides"], summary["setSize"]) == ("slides", 1, 0)

    _save_set(db, ["p1"])
    asset["updatedAt"] = datetime(2026, 10, 4, tzinfo=timezone.utc)
    summary = main.run_list_slideshows(uid=UID, db=db)["slideshows"][0]
    assert (summary["stage"], summary["setSize"]) == ("set", 1)


def test_a_slideshow_has_its_passed_slides_with_plan_details():
    db = FakeDB()
    _with_slides(db)

    result = main.run_get_slideshow(uid=UID, asset_id=ASSET_ID, db=db)

    assert result["finalSet"] is None
    assert [s["planId"] for s in result["passedSlides"]] == ["p1", "p2"]
    first = result["passedSlides"][0]
    assert (first["number"], first["title"]) == (1, "Cozy coffee run")
    assert first["text"] == _confirmed_plans()["plans"][0]["copy"]["text"]
    assert (first["width"], first["height"]) == (704, 1536)
    assert first["imagePath"].startswith(f"{FOLDER}slides/")


def test_a_slideshow_leaves_out_slides_that_did_not_pass():
    db = FakeDB()
    _with_slides(db, p2_status="rejected")
    result = main.run_get_slideshow(uid=UID, asset_id=ASSET_ID, db=db)
    assert [s["planId"] for s in result["passedSlides"]] == ["p1"]


def test_a_saved_set_is_checked_again_when_opened():
    db = FakeDB()
    _with_slides(db)
    _save_set(db, ["p2", "p1"])
    db.docs[ASSET_ID].subcollections["generationRuns"].docs[GEN_RUN_2].data["status"] = "rejected"

    result = main.run_get_slideshow(uid=UID, asset_id=ASSET_ID, db=db)

    assert [s["planId"] for s in result["finalSet"]["slides"]] == ["p1"]
    assert result["finalSet"]["slides"][0]["title"] == "Cozy coffee run"


def test_someone_elses_slideshow_is_not_found():
    db = FakeDB()
    _with_slides(db)
    with pytest.raises(https_fn.HttpsError) as error:
        main.run_get_slideshow(uid="someone-else", asset_id=ASSET_ID, db=db)
    assert error.value.code == Code.NOT_FOUND
