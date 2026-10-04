import os
from pathlib import Path
from types import SimpleNamespace

import pytest
from google.api_core.exceptions import AlreadyExists
from PIL import Image

os.environ.setdefault("GCLOUD_PROJECT", "justpost-test")

import main  # noqa: E402
from firebase_functions import https_fn  # noqa: E402

UID = "user-1"
JOB_ID = "job12345abc"


class FakeBlob:
    def __init__(self, name: str, data: bytes = b"", size: int | None = None):
        self.name = name
        self.data = data
        self.size = len(data) if size is None else size
        self.content_type = None

    def download_to_filename(self, path: str) -> None:
        Path(path).write_bytes(self.data)

    def upload_from_filename(self, path: str, content_type: str) -> None:
        self.data = Path(path).read_bytes()
        self.content_type = content_type


class FakeBucket:
    def __init__(self, blobs: list[FakeBlob]):
        self.blobs = blobs
        self.uploads: dict[str, FakeBlob] = {}
        self.prefixes: list[str] = []

    def list_blobs(self, prefix: str):
        self.prefixes.append(prefix)
        return [blob for blob in self.blobs if blob.name.startswith(prefix)]

    def blob(self, name: str) -> FakeBlob:
        return self.uploads.setdefault(name, FakeBlob(name))


class FakeDocRef:
    def __init__(self):
        self.data: dict | None = None

    def create(self, data: dict) -> None:
        if self.data is not None:
            raise AlreadyExists("exists")
        self.data = dict(data)

    def update(self, data: dict) -> None:
        assert self.data is not None
        self.data.update(data)


class FakeDB:
    def __init__(self):
        self.docs: dict[str, FakeDocRef] = {}

    def collection(self, name: str):
        assert name == "jobs"
        return SimpleNamespace(
            document=lambda doc_id: self.docs.setdefault(doc_id, FakeDocRef())
        )


def _jpeg_bytes(tmp_path: Path, name: str) -> bytes:
    path = tmp_path / name
    Image.new("RGB", (8, 8), "white").save(path, "JPEG")
    return path.read_bytes()


def _input_blobs(tmp_path: Path, count: int) -> list[FakeBlob]:
    return [
        FakeBlob(
            f"jobs/{UID}/{JOB_ID}/input/slide{index:02d}.jpg",
            _jpeg_bytes(tmp_path, f"in{index}.jpg"),
        )
        for index in range(1, count + 1)
    ]


def fake_run_carousel(client, paths, output_root, on_analyzed, on_slide):
    on_analyzed(SimpleNamespace())
    for index, path in enumerate(paths):
        out = output_root / path.stem / f"{path.stem}_shipped.png"
        out.parent.mkdir(parents=True, exist_ok=True)
        Image.open(path).save(out, "PNG")
        passed = index == 0
        on_slide(
            {
                "path": str(path),
                "verification": SimpleNamespace(
                    passed=passed, fallback_to_original=not passed
                ),
                "skip_reason": None,
            }
        )


def _run(bucket, db, job_id=JOB_ID, run_carousel=fake_run_carousel):
    return main.run_job(
        uid=UID,
        job_id=job_id,
        bucket=bucket,
        db=db,
        client=object(),
        run_carousel=run_carousel,
    )


def test_uploads_each_shipped_slide_and_records_results(tmp_path):
    bucket = FakeBucket(_input_blobs(tmp_path, 2))
    db = FakeDB()

    assert _run(bucket, db) == {"jobId": JOB_ID, "status": "done"}

    assert bucket.prefixes == [f"jobs/{UID}/{JOB_ID}/input/"]
    assert set(bucket.uploads) == {
        f"jobs/{UID}/{JOB_ID}/output/slide01.png",
        f"jobs/{UID}/{JOB_ID}/output/slide02.png",
    }
    job = db.docs[JOB_ID].data
    assert job["uid"] == UID
    assert job["status"] == "done"
    assert job["completedSlides"] == 2
    assert [s["edited"] for s in job["slides"]] == [True, False]
    assert job["slides"][1]["fallbackToOriginal"] is True


@pytest.mark.parametrize("job_id", [None, "short", "../../other", "a" * 65])
def test_rejects_invalid_job_ids(tmp_path, job_id):
    with pytest.raises(https_fn.HttpsError) as error:
        _run(FakeBucket(_input_blobs(tmp_path, 1)), FakeDB(), job_id=job_id)
    assert error.value.code == https_fn.FunctionsErrorCode.INVALID_ARGUMENT


def test_rejects_jobs_without_slides():
    with pytest.raises(https_fn.HttpsError) as error:
        _run(FakeBucket([]), FakeDB())
    assert error.value.code == https_fn.FunctionsErrorCode.INVALID_ARGUMENT


def test_rejects_oversized_slides(tmp_path):
    blobs = _input_blobs(tmp_path, 1)
    blobs[0].size = main.MAX_SLIDE_BYTES + 1
    with pytest.raises(https_fn.HttpsError) as error:
        _run(FakeBucket(blobs), FakeDB())
    assert error.value.code == https_fn.FunctionsErrorCode.INVALID_ARGUMENT


def test_a_job_runs_only_once(tmp_path):
    bucket = FakeBucket(_input_blobs(tmp_path, 1))
    db = FakeDB()
    _run(bucket, db)
    with pytest.raises(https_fn.HttpsError) as error:
        _run(bucket, db)
    assert error.value.code == https_fn.FunctionsErrorCode.ALREADY_EXISTS


def test_pipeline_errors_mark_the_job_failed(tmp_path):
    def broken(*_args, **_kwargs):
        raise RuntimeError("model unavailable")

    db = FakeDB()
    with pytest.raises(https_fn.HttpsError) as error:
        _run(FakeBucket(_input_blobs(tmp_path, 1)), db, run_carousel=broken)
    assert error.value.code == https_fn.FunctionsErrorCode.INTERNAL
    job = db.docs[JOB_ID].data
    assert job["status"] == "failed"
    assert "model unavailable" not in job["error"]
