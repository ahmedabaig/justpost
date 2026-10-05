from __future__ import annotations

import json
import os
from io import BytesIO
from types import SimpleNamespace

import pytest
from google.api_core.exceptions import AlreadyExists
from PIL import Image

os.environ.setdefault("GCLOUD_PROJECT", "justpost-test")

import main  # noqa: E402
from firebase_functions import https_fn  # noqa: E402
from justpost.model_io import ModelReply  # noqa: E402
from test_analysis import ScriptedModel, _sample  # noqa: E402
from test_blueprint import _ai_reply  # noqa: E402

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
        assert self.data is not None
        self.data.update(data)

    def get(self):
        data = self.data
        return SimpleNamespace(
            exists=data is not None, to_dict=lambda: dict(data) if data else None
        )

    def collection(self, name: str) -> FakeCollection:
        return self.subcollections.setdefault(name, FakeCollection())


class FakeCollection:
    def __init__(self):
        self.docs: dict[str, FakeDocRef] = {}

    def document(self, doc_id: str | None = None) -> FakeDocRef:
        doc_id = doc_id or f"run{len(self.docs) + 1}"
        return self.docs.setdefault(doc_id, FakeDocRef(doc_id))


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
