"""Firebase Cloud Functions entry point for JustPost slideshow variations."""

from __future__ import annotations

import logging
import re
import shutil
import tempfile
from collections.abc import Callable
from pathlib import Path
from typing import Any

from firebase_admin import firestore, initialize_app, storage
from firebase_functions import https_fn, options
from firebase_functions.params import SecretParam
from google.api_core.exceptions import AlreadyExists

# The OpenAI and Gemini SDKs read these from the environment at runtime.
OPENAI_API_KEY = SecretParam("OPENAI_API_KEY")
GEMINI_API_KEY = SecretParam("GEMINI_API_KEY")

MAX_SLIDES = 20
MAX_SLIDE_BYTES = 15 * 1024 * 1024
INPUT_SUFFIXES = {".jpg", ".jpeg", ".png", ".webp"}
JOB_ID_PATTERN = re.compile(r"^[A-Za-z0-9_-]{8,64}$")

initialize_app()
logger = logging.getLogger("justpost")


def _fail(code: https_fn.FunctionsErrorCode, message: str) -> https_fn.HttpsError:
    return https_fn.HttpsError(code=code, message=message)


def _slide_record(result: dict, input_path: str, output_path: str) -> dict[str, Any]:
    verification = result["verification"]
    return {
        "slideId": Path(result["path"]).stem,
        "inputPath": input_path,
        "outputPath": output_path,
        "edited": verification is not None and not verification.fallback_to_original,
        "verificationPassed": None if verification is None else verification.passed,
        "fallbackToOriginal": None
        if verification is None
        else verification.fallback_to_original,
        "skipReason": result.get("skip_reason"),
    }


@https_fn.on_call(
    region="us-central1",
    memory=options.MemoryOption.GB_2,
    cpu=2,
    timeout_sec=1800,
    concurrency=1,
    max_instances=5,
    secrets=[OPENAI_API_KEY, GEMINI_API_KEY],
    enforce_app_check=True,
)
def create_variation(req: https_fn.CallableRequest) -> dict[str, Any]:
    """Generate one variation of the slides uploaded under jobs/{uid}/{jobId}/input/."""
    if req.auth is None:
        raise _fail(https_fn.FunctionsErrorCode.UNAUTHENTICATED, "Sign in first.")
    data = req.data if isinstance(req.data, dict) else {}
    from google import genai

    from justpost_phase1.pipeline import run_carousel

    return run_job(
        uid=req.auth.uid,
        job_id=data.get("jobId"),
        bucket=storage.bucket(),
        db=firestore.client(),
        client=genai.Client(),
        run_carousel=run_carousel,
    )


def run_job(
    uid: str,
    job_id: Any,
    bucket,
    db,
    client,
    run_carousel: Callable[..., Any],
) -> dict[str, Any]:
    if not isinstance(job_id, str) or not JOB_ID_PATTERN.match(job_id):
        raise _fail(https_fn.FunctionsErrorCode.INVALID_ARGUMENT, "Invalid jobId.")

    prefix = f"jobs/{uid}/{job_id}/input/"
    blobs = sorted(
        (
            blob
            for blob in bucket.list_blobs(prefix=prefix)
            if Path(blob.name).suffix.lower() in INPUT_SUFFIXES
        ),
        key=lambda blob: blob.name,
    )
    if not 1 <= len(blobs) <= MAX_SLIDES:
        raise _fail(
            https_fn.FunctionsErrorCode.INVALID_ARGUMENT,
            f"Upload between 1 and {MAX_SLIDES} slides.",
        )
    if any((blob.size or 0) > MAX_SLIDE_BYTES for blob in blobs):
        raise _fail(
            https_fn.FunctionsErrorCode.INVALID_ARGUMENT, "A slide is too large."
        )

    job_ref = db.collection("jobs").document(job_id)
    try:
        job_ref.create(
            {
                "uid": uid,
                "status": "analyzing",
                "slideCount": len(blobs),
                "completedSlides": 0,
                "slides": [],
                "error": None,
                "createdAt": firestore.SERVER_TIMESTAMP,
                "updatedAt": firestore.SERVER_TIMESTAMP,
            }
        )
    except AlreadyExists:
        raise _fail(
            https_fn.FunctionsErrorCode.ALREADY_EXISTS, "This job has already run."
        ) from None

    workdir = Path(tempfile.mkdtemp(prefix=f"job-{job_id}-"))
    try:
        input_dir = workdir / "input"
        input_dir.mkdir()
        local_paths: list[Path] = []
        input_paths: dict[str, str] = {}
        for index, blob in enumerate(blobs, start=1):
            slide_id = f"slide{index:02d}"
            local = input_dir / f"{slide_id}{Path(blob.name).suffix.lower()}"
            blob.download_to_filename(str(local))
            local_paths.append(local)
            input_paths[slide_id] = blob.name

        output_root = workdir / "output"
        slides: list[dict[str, Any]] = []

        def on_analyzed(_analysis) -> None:
            job_ref.update(
                {"status": "generating", "updatedAt": firestore.SERVER_TIMESTAMP}
            )

        def on_slide(result: dict) -> None:
            slide_id = Path(result["path"]).stem
            output_path = f"jobs/{uid}/{job_id}/output/{slide_id}.png"
            output_blob = bucket.blob(output_path)
            output_blob.upload_from_filename(
                str(output_root / slide_id / f"{slide_id}_shipped.png"),
                content_type="image/png",
            )
            slides.append(_slide_record(result, input_paths[slide_id], output_path))
            job_ref.update(
                {
                    "slides": slides,
                    "completedSlides": len(slides),
                    "updatedAt": firestore.SERVER_TIMESTAMP,
                }
            )

        run_carousel(
            client,
            local_paths,
            output_root,
            on_analyzed=on_analyzed,
            on_slide=on_slide,
        )
        job_ref.update({"status": "done", "updatedAt": firestore.SERVER_TIMESTAMP})
        return {"jobId": job_id, "status": "done"}
    except Exception:
        logger.exception("variation job %s failed", job_id)
        job_ref.update(
            {
                "status": "failed",
                "error": "Generation failed. Please try again.",
                "updatedAt": firestore.SERVER_TIMESTAMP,
            }
        )
        raise _fail(
            https_fn.FunctionsErrorCode.INTERNAL, "Generation failed."
        ) from None
    finally:
        shutil.rmtree(workdir, ignore_errors=True)
