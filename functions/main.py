"""Firebase Cloud Functions entry point for JustPost."""

from __future__ import annotations

import logging
import re
from collections.abc import Callable
from datetime import datetime, timezone
from pathlib import PurePosixPath
from typing import Any

from firebase_admin import firestore, initialize_app, storage
from firebase_functions import https_fn, options
from firebase_functions.params import BoolParam, SecretParam, StringParam
from google.api_core.exceptions import AlreadyExists

from justpost import blueprint
from justpost.analysis import analyze
from justpost.analysis_schema import SCHEMA_VERSION
from justpost.blueprint_schema import SCHEMA_VERSION as BLUEPRINT_SCHEMA_VERSION
from justpost.ingest import IngestError, ingest_image
from justpost.model_io import VisionModel
from justpost.openai_client import OpenAIVisionModel

MAX_UPLOAD_BYTES = 20 * 1024 * 1024
ORIGINAL_SUFFIXES = frozenset({".jpg", ".jpeg", ".png", ".webp", ".heic", ".heif"})
# Firestore auto-generated document IDs: 20 alphanumeric characters.
ASSET_ID_PATTERN = re.compile(r"^[A-Za-z0-9]{20}$")
# Each analysis or blueprint build can make two paid model requests.
DAILY_ANALYSIS_LIMIT = 20
DAILY_BLUEPRINT_LIMIT = 20

OPENAI_API_KEY = SecretParam("OPENAI_API_KEY")
ANALYSIS_MODEL = StringParam("ANALYSIS_MODEL", default="gpt-5.4-mini")
BLUEPRINT_MODEL = StringParam("BLUEPRINT_MODEL", default="gpt-5.4-mini")
# Turn off before an App Store release; raw model text is for inspection only.
EXPOSE_RAW_ANALYSIS = BoolParam("EXPOSE_RAW_ANALYSIS", default=True)

initialize_app()
logger = logging.getLogger("justpost")

Code = https_fn.FunctionsErrorCode


def _fail(code: https_fn.FunctionsErrorCode, message: str) -> https_fn.HttpsError:
    return https_fn.HttpsError(code=code, message=message)


@https_fn.on_call(
    region="us-central1",
    memory=options.MemoryOption.GB_1,
    cpu=1,
    timeout_sec=60,
    concurrency=1,
    max_instances=3,
    enforce_app_check=True,
)
def ingest_asset(req: https_fn.CallableRequest) -> dict[str, Any]:
    """Normalize the original uploaded to uploads/{uid}/{assetId}/."""
    if req.auth is None:
        raise _fail(Code.UNAUTHENTICATED, "Sign in first.")
    data = req.data if isinstance(req.data, dict) else {}
    return run_ingest(
        uid=req.auth.uid,
        asset_id=data.get("assetId"),
        bucket=storage.bucket(),
        db=firestore.client(),
    )


def run_ingest(uid: str, asset_id: Any, bucket, db) -> dict[str, Any]:
    if not isinstance(asset_id, str) or not ASSET_ID_PATTERN.match(asset_id):
        raise _fail(Code.INVALID_ARGUMENT, "Invalid assetId.")

    folder = f"uploads/{uid}/{asset_id}/"
    originals = [
        blob
        for blob in bucket.list_blobs(prefix=folder)
        if PurePosixPath(blob.name).stem == "original"
        and PurePosixPath(blob.name).suffix.lower() in ORIGINAL_SUFFIXES
    ]
    if len(originals) != 1:
        raise _fail(Code.FAILED_PRECONDITION, "Upload exactly one original first.")
    original = originals[0]
    if (original.size or 0) > MAX_UPLOAD_BYTES:
        raise _fail(Code.INVALID_ARGUMENT, "The image is larger than 20 MB.")

    asset_ref = db.collection("assets").document(asset_id)
    try:
        asset_ref.create(
            {
                "uid": uid,
                "status": "processing",
                "originalPath": original.name,
                "fileSize": original.size,
                "error": None,
                "createdAt": firestore.SERVER_TIMESTAMP,
                "updatedAt": firestore.SERVER_TIMESTAMP,
            }
        )
    except AlreadyExists:
        raise _fail(Code.ALREADY_EXISTS, "This asset was already ingested.") from None

    def mark_failed(message: str) -> None:
        asset_ref.update(
            {
                "status": "failed",
                "error": message,
                "updatedAt": firestore.SERVER_TIMESTAMP,
            }
        )

    try:
        result = ingest_image(original.download_as_bytes())
        working_path = f"{folder}working.png"
        analysis_path = f"{folder}analysis.webp"
        bucket.blob(working_path).upload_from_string(
            result.working_png, content_type="image/png"
        )
        bucket.blob(analysis_path).upload_from_string(
            result.analysis_webp, content_type="image/webp"
        )
    except IngestError as error:
        mark_failed(str(error))
        raise _fail(Code.INVALID_ARGUMENT, str(error)) from None
    except Exception:
        logger.exception("ingest of asset %s failed", asset_id)
        mark_failed("Processing failed. Please try again.")
        raise _fail(Code.INTERNAL, "Processing failed.") from None

    record = {
        "status": "ready",
        "workingPath": working_path,
        "analysisPath": analysis_path,
        "width": result.width,
        "height": result.height,
        "orientation": result.orientation,
        "sourceFormat": result.source_format,
        "mimeType": result.mime_type,
        "sourceWidth": result.source_width,
        "sourceHeight": result.source_height,
        "exifOrientation": result.exif_orientation,
        "hasAlpha": result.has_alpha,
        "colorProfile": result.color_profile,
    }
    asset_ref.update({**record, "updatedAt": firestore.SERVER_TIMESTAMP})
    return {
        "assetId": asset_id,
        "originalPath": original.name,
        "fileSize": original.size,
        **record,
    }


@https_fn.on_call(
    region="us-central1",
    memory=options.MemoryOption.MB_512,
    cpu=1,
    timeout_sec=120,
    concurrency=1,
    max_instances=3,
    enforce_app_check=True,
    secrets=[OPENAI_API_KEY],
)
def analyze_asset(req: https_fn.CallableRequest) -> dict[str, Any]:
    """Describe the creative structure of an ingested reference slide."""
    if req.auth is None:
        raise _fail(Code.UNAUTHENTICATED, "Sign in first.")
    data = req.data if isinstance(req.data, dict) else {}
    return run_analyze(
        uid=req.auth.uid,
        asset_id=data.get("assetId"),
        bucket=storage.bucket(),
        db=firestore.client(),
        model=OpenAIVisionModel(OPENAI_API_KEY.value, ANALYSIS_MODEL.value),
        expose_raw=EXPOSE_RAW_ANALYSIS.value,
    )


def take_daily_slot(db, uid: str, kind: str, limit: int) -> bool:
    """Counts one `kind` request against the user's UTC-day allowance, atomically."""
    day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    usage_ref = db.collection("usage").document(uid)
    day_field, used_field = f"{kind}Day", f"{kind}Used"

    @firestore.transactional
    def take(transaction) -> bool:
        snapshot = usage_ref.get(transaction=transaction)
        usage = snapshot.to_dict() if snapshot.exists else {}
        used = usage.get(used_field, 0) if usage.get(day_field) == day else 0
        if used >= limit:
            return False
        transaction.set(
            usage_ref,
            {
                day_field: day,
                used_field: used + 1,
                "updatedAt": firestore.SERVER_TIMESTAMP,
            },
            merge=True,
        )
        return True

    return take(db.transaction())


def take_daily_analysis_slot(db, uid: str) -> bool:
    return take_daily_slot(db, uid, "analyses", DAILY_ANALYSIS_LIMIT)


def take_daily_blueprint_slot(db, uid: str) -> bool:
    return take_daily_slot(db, uid, "blueprints", DAILY_BLUEPRINT_LIMIT)


def _owned_asset(db, uid: str, asset_id: Any):
    """Returns the asset's reference and data, or fails without revealing others'."""
    if not isinstance(asset_id, str) or not ASSET_ID_PATTERN.match(asset_id):
        raise _fail(Code.INVALID_ARGUMENT, "Invalid assetId.")
    asset_ref = db.collection("assets").document(asset_id)
    snapshot = asset_ref.get()
    asset = snapshot.to_dict() if snapshot.exists else None
    # Someone else's asset looks the same as a missing one.
    if not asset or asset.get("uid") != uid:
        raise _fail(Code.NOT_FOUND, "This slide was not found.")
    return asset_ref, asset


def _analysis_image_path(asset: dict[str, Any], uid: str, asset_id: str) -> str:
    analysis_path = asset.get("analysisPath")
    if asset.get("status") != "ready" or not isinstance(analysis_path, str):
        raise _fail(Code.FAILED_PRECONDITION, "This slide is not ready yet.")
    if not analysis_path.startswith(f"uploads/{uid}/{asset_id}/"):
        raise _fail(Code.FAILED_PRECONDITION, "This slide is not ready yet.")
    return analysis_path


def _checked_analysis(asset: dict[str, Any]) -> tuple[dict[str, Any], str]:
    analysis, run_id = asset.get("analysis"), asset.get("analysisRunId")
    if asset.get("analysisStatus") != "ready" or not analysis or not run_id:
        raise _fail(Code.FAILED_PRECONDITION, "Analyze this slide first.")
    return analysis, run_id


def _reply_attempts(attempts, expose_raw: bool) -> list[dict[str, Any]]:
    records = []
    for attempt in attempts:
        record = attempt.to_record()
        if not expose_raw:
            record.pop("rawText")
        records.append(record)
    return records


def run_analyze(
    uid: str,
    asset_id: Any,
    bucket,
    db,
    model: VisionModel,
    expose_raw: bool,
    take_slot: Callable[[Any, str], bool] = take_daily_analysis_slot,
) -> dict[str, Any]:
    asset_ref, asset = _owned_asset(db, uid, asset_id)
    analysis_path = _analysis_image_path(asset, uid, asset_id)

    if not take_slot(db, uid):
        raise _fail(
            Code.RESOURCE_EXHAUSTED,
            "You've reached today's analysis limit. Try again tomorrow.",
        )

    try:
        image = bucket.blob(analysis_path).download_as_bytes()
        outcome = analyze(image, model, expected_orientation=asset.get("orientation"))

        run_ref = asset_ref.collection("analysisRuns").document()
        status = "passed" if outcome.passed else "failed"
        run_ref.set(
            {
                "uid": uid,
                "status": status,
                "schemaVersion": SCHEMA_VERSION,
                "attempts": [attempt.to_record() for attempt in outcome.attempts],
                "createdAt": firestore.SERVER_TIMESTAMP,
            }
        )
        # `analysis` always belongs to `analysisRunId`, so a failed re-run clears it.
        asset_ref.update(
            {
                "analysis": outcome.result,
                "analysisStatus": "ready" if outcome.passed else "failed",
                "analysisRunId": run_ref.id,
                "updatedAt": firestore.SERVER_TIMESTAMP,
            }
        )
    except Exception:
        logger.exception("analysis of asset %s failed", asset_id)
        raise _fail(Code.INTERNAL, "Analysis failed.") from None

    return {
        "assetId": asset_id,
        "runId": run_ref.id,
        "status": status,
        "analysis": outcome.result,
        "rawExposed": expose_raw,
        "attempts": _reply_attempts(outcome.attempts, expose_raw),
    }


def _confirmed(asset: dict[str, Any]) -> dict[str, Any] | None:
    blueprint = asset.get("blueprint")
    if not blueprint:
        return None
    return {"blueprint": blueprint, "version": asset.get("blueprintVersion", 1)}


@https_fn.on_call(
    region="us-central1",
    memory=options.MemoryOption.MB_512,
    cpu=1,
    timeout_sec=120,
    concurrency=1,
    max_instances=3,
    enforce_app_check=True,
    secrets=[OPENAI_API_KEY],
)
def build_blueprint(req: https_fn.CallableRequest) -> dict[str, Any]:
    """Draft the creative blueprint for an analyzed reference slide."""
    if req.auth is None:
        raise _fail(Code.UNAUTHENTICATED, "Sign in first.")
    data = req.data if isinstance(req.data, dict) else {}
    return run_build_blueprint(
        uid=req.auth.uid,
        asset_id=data.get("assetId"),
        bucket=storage.bucket(),
        db=firestore.client(),
        model=OpenAIVisionModel(OPENAI_API_KEY.value, BLUEPRINT_MODEL.value),
        expose_raw=EXPOSE_RAW_ANALYSIS.value,
    )


def run_build_blueprint(
    uid: str,
    asset_id: Any,
    bucket,
    db,
    model: VisionModel,
    expose_raw: bool,
    take_slot: Callable[[Any, str], bool] = take_daily_blueprint_slot,
) -> dict[str, Any]:
    asset_ref, asset = _owned_asset(db, uid, asset_id)
    analysis_path = _analysis_image_path(asset, uid, asset_id)
    analysis, analysis_run_id = _checked_analysis(asset)

    if not take_slot(db, uid):
        raise _fail(
            Code.RESOURCE_EXHAUSTED,
            "You've reached today's blueprint limit. Try again tomorrow.",
        )

    try:
        image = bucket.blob(analysis_path).download_as_bytes()
        outcome = blueprint.build(analysis, analysis_run_id, image, model)

        run_ref = asset_ref.collection("blueprintRuns").document()
        status = "passed" if outcome.passed else "failed"
        run_ref.set(
            {
                "uid": uid,
                "status": status,
                "schemaVersion": BLUEPRINT_SCHEMA_VERSION,
                "analysisRunId": analysis_run_id,
                "attempts": [attempt.to_record() for attempt in outcome.attempts],
                "createdAt": firestore.SERVER_TIMESTAMP,
            }
        )
        # The draft always belongs to `blueprintDraftRunId`; the confirmed
        # blueprint is only ever replaced by save_blueprint.
        asset_ref.update(
            {
                "blueprintDraft": outcome.result,
                "blueprintDraftStatus": "ready" if outcome.passed else "failed",
                "blueprintDraftRunId": run_ref.id,
                "updatedAt": firestore.SERVER_TIMESTAMP,
            }
        )
    except Exception:
        logger.exception("blueprint for asset %s failed", asset_id)
        raise _fail(Code.INTERNAL, "Building the blueprint failed.") from None

    return {
        "assetId": asset_id,
        "runId": run_ref.id,
        "status": status,
        "draft": outcome.result,
        "analysisRunId": analysis_run_id,
        "confirmed": _confirmed(asset),
        "rawExposed": expose_raw,
        "attempts": _reply_attempts(outcome.attempts, expose_raw),
    }


@https_fn.on_call(
    region="us-central1",
    memory=options.MemoryOption.MB_256,
    timeout_sec=30,
    max_instances=3,
    enforce_app_check=True,
)
def save_blueprint(req: https_fn.CallableRequest) -> dict[str, Any]:
    """Check a user-edited blueprint and store it as the confirmed version."""
    if req.auth is None:
        raise _fail(Code.UNAUTHENTICATED, "Sign in first.")
    data = req.data if isinstance(req.data, dict) else {}
    return run_save_blueprint(
        uid=req.auth.uid,
        asset_id=data.get("assetId"),
        edited=data.get("blueprint"),
        db=firestore.client(),
    )


def run_save_blueprint(uid: str, asset_id: Any, edited: Any, db) -> dict[str, Any]:
    asset_ref, asset = _owned_asset(db, uid, asset_id)
    analysis, analysis_run_id = _checked_analysis(asset)
    if not isinstance(edited, dict):
        raise _fail(Code.INVALID_ARGUMENT, "Send the blueprint to save.")

    checked, report = blueprint.check_blueprint(edited, analysis, analysis_run_id, "user")
    if checked is None:
        if any(issue.startswith("analysisRunId") for issue in report.issues):
            raise _fail(
                Code.FAILED_PRECONDITION,
                "The analysis changed since this draft was built. Rebuild the draft.",
            )
        # Issues name fields and limits only, so they're safe to show.
        raise _fail(
            Code.INVALID_ARGUMENT,
            "This blueprint can't be saved: " + "; ".join(report.issues[:3]),
        )

    saved = checked.model_dump()
    version = int(asset.get("blueprintVersion") or 0) + 1
    asset_ref.update(
        {
            "blueprint": saved,
            "blueprintVersion": version,
            "blueprintConfirmedAt": firestore.SERVER_TIMESTAMP,
            "updatedAt": firestore.SERVER_TIMESTAMP,
        }
    )
    return {"assetId": asset_id, "blueprint": saved, "version": version}
