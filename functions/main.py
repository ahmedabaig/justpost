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
from pydantic import ValidationError

from justpost import blueprint, generation, planning, render, validation
from justpost.analysis import analyze
from justpost.analysis_schema import SCHEMA_VERSION
from justpost.blueprint_schema import SCHEMA_VERSION as BLUEPRINT_SCHEMA_VERSION
from justpost.ingest import IngestError, ingest_image
from justpost.layout_schema import LayoutChoice
from justpost.model_io import ImageModel, VisionModel, validation_issues
from justpost.openai_client import OpenAIVisionModel
from justpost.openai_image import OpenAIImageModel
from justpost.plan_schema import MAX_HOOK_CHARS, MAX_PLANS, MIN_PLANS
from justpost.plan_schema import SCHEMA_VERSION as PLAN_SCHEMA_VERSION
from justpost.validation_schema import KeepClear

MAX_UPLOAD_BYTES = 20 * 1024 * 1024
ORIGINAL_SUFFIXES = frozenset({".jpg", ".jpeg", ".png", ".webp", ".heic", ".heif"})
# Firestore auto-generated document IDs: 20 alphanumeric characters.
ASSET_ID_PATTERN = re.compile(r"^[A-Za-z0-9]{20}$")
# Each analysis, blueprint build or plan run can make two paid model requests.
DAILY_ANALYSIS_LIMIT = 20
DAILY_BLUEPRINT_LIMIT = 20
DAILY_PLAN_LIMIT = 20
# One paid image request each; images cost far more than text requests.
DAILY_IMAGE_LIMIT = 10
# Drawing text is cheap; this only stops a broken client from looping.
DAILY_RENDER_LIMIT = 200
LIBRARY_LIMIT = 50
# Plan IDs as plan_schema.ItemId allows them.
PLAN_ID_PATTERN = re.compile(r"^[a-z0-9_-]{1,40}$")
# Firestore auto-generated document IDs, as generationRuns uses.
RUN_ID_PATTERN = re.compile(r"^[A-Za-z0-9]{20}$")

OPENAI_API_KEY = SecretParam("OPENAI_API_KEY")
ANALYSIS_MODEL = StringParam("ANALYSIS_MODEL", default="gpt-5.4-mini")
BLUEPRINT_MODEL = StringParam("BLUEPRINT_MODEL", default="gpt-5.4-mini")
PLAN_MODEL = StringParam("PLAN_MODEL", default="gpt-5.4-mini")
IMAGE_MODEL = StringParam("IMAGE_MODEL", default="gpt-image-2")
IMAGE_QUALITY = StringParam("IMAGE_QUALITY", default="medium")
VALIDATION_MODEL = StringParam("VALIDATION_MODEL", default="gpt-5.4-mini")
# Turn off before an App Store release; raw model text and unchecked images
# are for inspection only.
EXPOSE_RAW_ANALYSIS = BoolParam("EXPOSE_RAW_ANALYSIS", default=True)

initialize_app()
logger = logging.getLogger("justpost")

Code = https_fn.FunctionsErrorCode


def _fail(code: https_fn.FunctionsErrorCode, message: str) -> https_fn.HttpsError:
    return https_fn.HttpsError(code=code, message=message)


_WRAPPED_INT_TYPES = frozenset(
    {
        "type.googleapis.com/google.protobuf.Int64Value",
        "type.googleapis.com/google.protobuf.UInt64Value",
    }
)


def _unwrap_ints(value: Any) -> Any:
    """Decode the `{"@type": ..Int64Value, "value": "1"}` wrappers the iOS and
    Android callable SDKs send for 64-bit integers; the Python SDK doesn't."""
    if isinstance(value, list):
        return [_unwrap_ints(item) for item in value]
    if not isinstance(value, dict):
        return value
    if value.keys() == {"@type", "value"} and value["@type"] in _WRAPPED_INT_TYPES:
        try:
            return int(value["value"])
        except (TypeError, ValueError):
            return value
    return {key: _unwrap_ints(item) for key, item in value.items()}


def _request_data(req: https_fn.CallableRequest) -> dict[str, Any]:
    data = _unwrap_ints(req.data)
    return data if isinstance(data, dict) else {}


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
    data = _request_data(req)
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
    data = _request_data(req)
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


def take_daily_plan_slot(db, uid: str) -> bool:
    return take_daily_slot(db, uid, "plans", DAILY_PLAN_LIMIT)


def take_daily_image_slot(db, uid: str) -> bool:
    return take_daily_slot(db, uid, "images", DAILY_IMAGE_LIMIT)


def take_daily_render_slot(db, uid: str) -> bool:
    return take_daily_slot(db, uid, "renders", DAILY_RENDER_LIMIT)


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
    data = _request_data(req)
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
    data = _request_data(req)
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


def _confirmed_blueprint(asset: dict[str, Any], analysis_run_id: str) -> tuple[dict[str, Any], int]:
    confirmed, version = asset.get("blueprint"), asset.get("blueprintVersion")
    if not confirmed or not version:
        raise _fail(Code.FAILED_PRECONDITION, "Save the blueprint first.")
    if confirmed.get("analysisRunId") != analysis_run_id:
        raise _fail(
            Code.FAILED_PRECONDITION,
            "The analysis changed since the blueprint was saved. "
            "Rebuild and save the blueprint first.",
        )
    return confirmed, int(version)


def _plan_count(value: Any) -> int:
    if value is None:
        return MIN_PLANS
    if isinstance(value, bool) or not isinstance(value, int) or not MIN_PLANS <= value <= MAX_PLANS:
        raise _fail(
            Code.INVALID_ARGUMENT, f"Ask for {MIN_PLANS} to {MAX_PLANS} variations."
        )
    return value


def _confirmed_plans(asset: dict[str, Any]) -> dict[str, Any] | None:
    plans = asset.get("plans")
    if not plans:
        return None
    return {"plans": plans, "version": asset.get("plansVersion", 1)}


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
def plan_variations(req: https_fn.CallableRequest) -> dict[str, Any]:
    """Draft variation plans from a slide's confirmed blueprint."""
    if req.auth is None:
        raise _fail(Code.UNAUTHENTICATED, "Sign in first.")
    data = _request_data(req)
    return run_plan_variations(
        uid=req.auth.uid,
        asset_id=data.get("assetId"),
        count=data.get("count"),
        bucket=storage.bucket(),
        db=firestore.client(),
        model=OpenAIVisionModel(OPENAI_API_KEY.value, PLAN_MODEL.value),
        expose_raw=EXPOSE_RAW_ANALYSIS.value,
    )


def run_plan_variations(
    uid: str,
    asset_id: Any,
    count: Any,
    bucket,
    db,
    model: VisionModel,
    expose_raw: bool,
    take_slot: Callable[[Any, str], bool] = take_daily_plan_slot,
) -> dict[str, Any]:
    asset_ref, asset = _owned_asset(db, uid, asset_id)
    count = _plan_count(count)
    analysis_path = _analysis_image_path(asset, uid, asset_id)
    analysis, analysis_run_id = _checked_analysis(asset)
    confirmed, blueprint_version = _confirmed_blueprint(asset, analysis_run_id)

    if not take_slot(db, uid):
        raise _fail(
            Code.RESOURCE_EXHAUSTED,
            "You've reached today's planning limit. Try again tomorrow.",
        )

    try:
        image = bucket.blob(analysis_path).download_as_bytes()
        outcome = planning.plan(
            confirmed, blueprint_version, analysis, analysis_run_id, count, image, model
        )

        run_ref = asset_ref.collection("planRuns").document()
        status = "passed" if outcome.passed else "failed"
        run_ref.set(
            {
                "uid": uid,
                "status": status,
                "schemaVersion": PLAN_SCHEMA_VERSION,
                "analysisRunId": analysis_run_id,
                "blueprintVersion": blueprint_version,
                "count": count,
                "attempts": [attempt.to_record() for attempt in outcome.attempts],
                "createdAt": firestore.SERVER_TIMESTAMP,
            }
        )
        # The draft always belongs to `plansDraftRunId`; the confirmed plans
        # are only ever replaced by save_plans.
        asset_ref.update(
            {
                "plansDraft": outcome.result,
                "plansDraftStatus": "ready" if outcome.passed else "failed",
                "plansDraftRunId": run_ref.id,
                "updatedAt": firestore.SERVER_TIMESTAMP,
            }
        )
    except Exception:
        logger.exception("planning for asset %s failed", asset_id)
        raise _fail(Code.INTERNAL, "Planning the variations failed.") from None

    return {
        "assetId": asset_id,
        "runId": run_ref.id,
        "status": status,
        "count": count,
        "draft": outcome.result,
        "blueprintVersion": blueprint_version,
        "analysisRunId": analysis_run_id,
        "confirmed": _confirmed_plans(asset),
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
def save_plans(req: https_fn.CallableRequest) -> dict[str, Any]:
    """Check user-edited variation plans and store them as the confirmed version."""
    if req.auth is None:
        raise _fail(Code.UNAUTHENTICATED, "Sign in first.")
    data = _request_data(req)
    return run_save_plans(
        uid=req.auth.uid,
        asset_id=data.get("assetId"),
        edited=data.get("plans"),
        db=firestore.client(),
    )


def run_save_plans(uid: str, asset_id: Any, edited: Any, db) -> dict[str, Any]:
    asset_ref, asset = _owned_asset(db, uid, asset_id)
    _, analysis_run_id = _checked_analysis(asset)
    confirmed, blueprint_version = _confirmed_blueprint(asset, analysis_run_id)
    if not isinstance(edited, dict):
        raise _fail(Code.INVALID_ARGUMENT, "Send the plans to save.")

    checked, report = planning.check_plans(
        edited, confirmed, blueprint_version, analysis_run_id, "user"
    )
    if checked is None:
        if any(
            issue.startswith(("blueprintVersion", "analysisRunId"))
            for issue in report.issues
        ):
            raise _fail(
                Code.FAILED_PRECONDITION,
                "The blueprint changed since these plans were written. Plan again.",
            )
        # Issues name fields and limits only, so they're safe to show.
        raise _fail(
            Code.INVALID_ARGUMENT,
            "These plans can't be saved: " + "; ".join(report.issues[:3]),
        )

    saved = planning.dump(checked)
    version = int(asset.get("plansVersion") or 0) + 1
    asset_ref.update(
        {
            "plans": saved,
            "plansVersion": version,
            "plansConfirmedAt": firestore.SERVER_TIMESTAMP,
            "updatedAt": firestore.SERVER_TIMESTAMP,
        }
    )
    return {"assetId": asset_id, "plans": saved, "version": version}


@https_fn.on_call(
    region="us-central1",
    memory=options.MemoryOption.GB_1,
    cpu=1,
    timeout_sec=360,
    concurrency=1,
    max_instances=5,
    enforce_app_check=True,
    secrets=[OPENAI_API_KEY],
)
def generate_variation(req: https_fn.CallableRequest) -> dict[str, Any]:
    """Create one image from one of a slide's confirmed plans, then check it."""
    if req.auth is None:
        raise _fail(Code.UNAUTHENTICATED, "Sign in first.")
    data = _request_data(req)
    return run_generate_variation(
        uid=req.auth.uid,
        asset_id=data.get("assetId"),
        plan_id=data.get("planId"),
        bucket=storage.bucket(),
        db=firestore.client(),
        model=OpenAIImageModel(OPENAI_API_KEY.value, IMAGE_MODEL.value, IMAGE_QUALITY.value),
        checker=OpenAIVisionModel(OPENAI_API_KEY.value, VALIDATION_MODEL.value),
        quality=IMAGE_QUALITY.value,
        expose_images=EXPOSE_RAW_ANALYSIS.value,
    )


def _check_summary(checks: list[dict[str, Any]], expose_notes: bool) -> list[dict[str, Any]]:
    """The checks as the app may show them; the model's notes only for inspection."""
    keys = ("id", "kind", "question", "answer", "passed") + (("note",) if expose_notes else ())
    return [{key: check[key] for key in keys} for check in checks]


def run_generate_variation(
    uid: str,
    asset_id: Any,
    plan_id: Any,
    bucket,
    db,
    model: ImageModel,
    checker: VisionModel,
    quality: str,
    expose_images: bool,
    take_slot: Callable[[Any, str], bool] = take_daily_image_slot,
) -> dict[str, Any]:
    asset_ref, asset = _owned_asset(db, uid, asset_id)
    if not isinstance(plan_id, str) or not PLAN_ID_PATTERN.match(plan_id):
        raise _fail(Code.INVALID_ARGUMENT, "Invalid planId.")
    analysis_path = _analysis_image_path(asset, uid, asset_id)
    _, analysis_run_id = _checked_analysis(asset)
    confirmed, blueprint_version = _confirmed_blueprint(asset, analysis_run_id)

    plans, plans_version = asset.get("plans"), asset.get("plansVersion")
    if not plans or not plans_version:
        raise _fail(Code.FAILED_PRECONDITION, "Save the plans first.")
    if generation.plans_are_stale(plans, blueprint_version, analysis_run_id):
        raise _fail(
            Code.FAILED_PRECONDITION,
            "The blueprint changed since these plans were saved. Plan again.",
        )
    plan = generation.find_plan(plans, plan_id)
    if plan is None:
        raise _fail(Code.NOT_FOUND, "This plan was not found.")
    width, height = asset.get("width"), asset.get("height")
    if not isinstance(width, int) or not isinstance(height, int) or width < 1 or height < 1:
        raise _fail(Code.FAILED_PRECONDITION, "This slide is not ready yet.")

    size = generation.output_size(width, height)
    request = generation.build_request(confirmed, plan)

    if not take_slot(db, uid):
        raise _fail(
            Code.RESOURCE_EXHAUSTED,
            "You've reached today's image limit. Try again tomorrow.",
        )

    try:
        reference = bucket.blob(analysis_path).download_as_bytes()
        outcome = generation.generate(request, reference, size, model)

        run_ref = asset_ref.collection("generationRuns").document()
        status, issues, image_path, check = "failed", list(outcome.report.issues), None, None
        if outcome.passed:
            image_path = f"uploads/{uid}/{asset_id}/variations/{run_ref.id}.png"
            bucket.blob(image_path).upload_from_string(outcome.png, content_type="image/png")
            check = validation.validate(checker, confirmed, plan, reference, outcome.png)
            status, issues = check.status, check.reasons

        check_record = check.to_record() if check else None
        out_width, out_height = size if outcome.passed else (None, None)
        run_ref.set(
            {
                "uid": uid,
                "planId": plan_id,
                "plansVersion": plans_version,
                "blueprintVersion": blueprint_version,
                "analysisRunId": analysis_run_id,
                "model": outcome.model,
                "quality": quality,
                "size": generation.size_text(size),
                "request": request,
                "status": status,
                "issues": issues,
                "validation": check_record,
                "latencyMs": outcome.latency_ms,
                "inputTokens": outcome.input_tokens,
                "outputTokens": outcome.output_tokens,
                "imagePath": image_path,
                "width": out_width,
                "height": out_height,
                "createdAt": firestore.SERVER_TIMESTAMP,
            }
        )
        asset_ref.update(
            {
                f"variations.{plan_id}": {
                    "runId": run_ref.id,
                    "status": status,
                    "imagePath": image_path if status == "passed" else None,
                    "width": out_width,
                    "height": out_height,
                    "plansVersion": plans_version,
                },
                "updatedAt": firestore.SERVER_TIMESTAMP,
            }
        )
    except Exception:
        logger.exception("image for asset %s plan %s failed", asset_id, plan_id)
        raise _fail(Code.INTERNAL, "Creating the image failed.") from None

    shown = status == "passed" or expose_images
    return {
        "assetId": asset_id,
        "planId": plan_id,
        "runId": run_ref.id,
        "status": status,
        "issues": issues,
        "checks": _check_summary(check_record["checks"], expose_images) if check_record else [],
        "model": outcome.model,
        "latencyMs": outcome.latency_ms + (check.latency_ms if check else 0),
        "plansVersion": plans_version,
        "width": out_width,
        "height": out_height,
        "imageExposed": shown,
        "imagePath": image_path if shown else None,
    }


@https_fn.on_call(
    region="us-central1",
    memory=options.MemoryOption.MB_512,
    cpu=1,
    timeout_sec=30,
    max_instances=5,
    enforce_app_check=True,
)
def render_slide(req: https_fn.CallableRequest) -> dict[str, Any]:
    """Draw a plan's slide text onto one of its checked images."""
    if req.auth is None:
        raise _fail(Code.UNAUTHENTICATED, "Sign in first.")
    data = _request_data(req)
    return run_render_slide(
        uid=req.auth.uid,
        asset_id=data.get("assetId"),
        run_id=data.get("runId"),
        layout=data.get("layout"),
        bucket=storage.bucket(),
        db=firestore.client(),
        expose_images=EXPOSE_RAW_ANALYSIS.value,
    )


# `unchecked` images come from before checks existed; like rejected and
# unverified ones, they can only be drawn on with inspection on.
DRAWABLE_STATUSES = frozenset({"passed", "rejected", "unverified", "unchecked"})


def _keep_clear(run: dict[str, Any]) -> list[dict[str, Any]]:
    areas = (run.get("validation") or {}).get("keepClear") or []
    try:
        return [KeepClear.model_validate(area).model_dump() for area in areas]
    except ValidationError:
        logger.warning("ignoring malformed keep-clear areas on a generation run")
        return []


def _plan_text(plan: dict[str, Any]) -> str | None:
    """The plan's slide text, checked again against the Phase 4 rules."""
    copy = plan.get("copy")
    if copy is None:
        return None
    text = copy.get("text") if isinstance(copy, dict) else None
    if (
        not isinstance(text, str)
        or not text.strip()
        or len(text) > MAX_HOOK_CHARS
        or planning.copy_issues("plan", text)
    ):
        raise _fail(Code.FAILED_PRECONDITION, "This plan's slide text can't be used. Edit the plan.")
    return text.strip()


def run_render_slide(
    uid: str,
    asset_id: Any,
    run_id: Any,
    layout: Any,
    bucket,
    db,
    expose_images: bool,
    take_slot: Callable[[Any, str], bool] = take_daily_render_slot,
) -> dict[str, Any]:
    asset_ref, asset = _owned_asset(db, uid, asset_id)
    if not isinstance(run_id, str) or not RUN_ID_PATTERN.match(run_id):
        raise _fail(Code.INVALID_ARGUMENT, "Invalid runId.")
    try:
        choice = LayoutChoice.model_validate({} if layout is None else layout)
    except ValidationError as error:
        raise _fail(
            Code.INVALID_ARGUMENT,
            "This layout can't be used: " + "; ".join(validation_issues(error)[:3]),
        ) from None

    snapshot = asset_ref.collection("generationRuns").document(run_id).get()
    run = snapshot.to_dict() if snapshot.exists else None
    image_path = (run or {}).get("imagePath")
    if (
        not run
        or run.get("uid") != uid
        or run.get("status") not in DRAWABLE_STATUSES
        or not isinstance(image_path, str)
        or not image_path.startswith(f"uploads/{uid}/{asset_id}/variations/")
    ):
        raise _fail(Code.NOT_FOUND, "This image was not found.")
    if run.get("status") != "passed" and not expose_images:
        raise _fail(Code.FAILED_PRECONDITION, "This image didn't pass its checks.")
    keep_clear = _keep_clear(run)

    analysis, analysis_run_id = _checked_analysis(asset)
    confirmed, blueprint_version = _confirmed_blueprint(asset, analysis_run_id)
    plans, plans_version = asset.get("plans"), asset.get("plansVersion")
    if (
        not plans
        or run.get("plansVersion") != plans_version
        or generation.plans_are_stale(plans, blueprint_version, analysis_run_id)
    ):
        raise _fail(
            Code.FAILED_PRECONDITION,
            "The plans changed since this image was made. Create the images again.",
        )
    plan_id = run.get("planId")
    plan = generation.find_plan(plans, plan_id)
    if plan is None:
        raise _fail(
            Code.FAILED_PRECONDITION,
            "The plans changed since this image was made. Create the images again.",
        )
    text = _plan_text(plan)
    copy_role = (confirmed.get("copyStrategy") or {}).get("role", "none")

    if not take_slot(db, uid):
        raise _fail(
            Code.RESOURCE_EXHAUSTED,
            "You've reached today's limit for adding text. Try again tomorrow.",
        )

    # A run's first slide moves its text off the subject by itself; later choices
    # are the user's, so a covering position is refused instead.
    current_slide = (asset.get("slides") or {}).get(plan_id) or {}
    first_render = current_slide.get("generationRunId") != run_id

    try:
        image = bucket.blob(image_path).download_as_bytes()
        outcome = render.render_slide(
            image,
            text,
            choice,
            analysis,
            copy_role,
            keep_clear=keep_clear,
            find_clear_position=first_render,
        )

        render_ref = asset_ref.collection("slideRenders").document()
        status = "rendered" if outcome.passed else "failed"
        slide_path = None
        if outcome.passed:
            slide_path = f"uploads/{uid}/{asset_id}/slides/{render_ref.id}.png"
            bucket.blob(slide_path).upload_from_string(outcome.png, content_type="image/png")

        render_ref.set(
            {
                "uid": uid,
                "generationRunId": run_id,
                "planId": plan_id,
                "plansVersion": plans_version,
                "layout": outcome.layout,
                "text": text,
                "fontSizePx": outcome.font_size_px,
                "lines": outcome.lines,
                "width": outcome.width,
                "height": outcome.height,
                "status": status,
                "issues": list(outcome.report.issues),
                "imagePath": slide_path,
                "textRegion": outcome.text_region,
                "keepClear": keep_clear,
                "createdAt": firestore.SERVER_TIMESTAMP,
            }
        )
        # A failed redraw leaves the last good slide in place.
        if outcome.passed:
            asset_ref.update(
                {
                    f"slides.{plan_id}": {
                        "renderId": render_ref.id,
                        "status": status,
                        "imagePath": slide_path,
                        "layout": outcome.layout,
                        "generationRunId": run_id,
                    },
                    "updatedAt": firestore.SERVER_TIMESTAMP,
                }
            )
    except Exception:
        logger.exception("render for asset %s run %s failed", asset_id, run_id)
        raise _fail(Code.INTERNAL, "Adding the text failed.") from None

    return {
        "assetId": asset_id,
        "planId": plan_id,
        "runId": run_id,
        "renderId": render_ref.id,
        "status": status,
        "issues": list(outcome.report.issues),
        "layout": outcome.layout,
        "hasText": text is not None,
        "fontSizePx": outcome.font_size_px,
        "lines": outcome.lines,
        "width": outcome.width,
        "height": outcome.height,
        "imageExposed": True,
        "imagePath": slide_path,
    }


# Final set and Library


def _plans_current(asset: dict[str, Any]) -> bool:
    plans = asset.get("plans")
    return bool(plans) and not generation.plans_are_stale(
        plans, asset.get("blueprintVersion"), asset.get("analysisRunId")
    )


def _passed_run(asset_ref, uid: str, run_id: Any) -> dict[str, Any] | None:
    if not isinstance(run_id, str) or not RUN_ID_PATTERN.match(run_id):
        return None
    snapshot = asset_ref.collection("generationRuns").document(run_id).get()
    run = snapshot.to_dict() if snapshot.exists else None
    if not run or run.get("uid") != uid or run.get("status") != "passed":
        return None
    return run


def _passed_slide(
    asset_ref, asset: dict[str, Any], uid: str, asset_id: str, plan_id: str
) -> dict[str, Any] | None:
    """The plan's current slide, if it was drawn on an image that passed its
    check and was made from the current plans."""
    slide = (asset.get("slides") or {}).get(plan_id) or {}
    path = slide.get("imagePath")
    if (
        slide.get("status") != "rendered"
        or not isinstance(path, str)
        or not path.startswith(f"uploads/{uid}/{asset_id}/slides/")
    ):
        return None
    run = _passed_run(asset_ref, uid, slide.get("generationRunId"))
    if not run or run.get("planId") != plan_id or run.get("plansVersion") != asset.get("plansVersion"):
        return None
    return {
        "planId": plan_id,
        "renderId": slide.get("renderId"),
        "generationRunId": slide.get("generationRunId"),
        "imagePath": path,
        "width": run.get("width"),
        "height": run.get("height"),
    }


def _plan_details(plan: dict[str, Any], number: int) -> dict[str, Any]:
    copy = plan.get("copy") if isinstance(plan.get("copy"), dict) else {}
    return {"number": number, "title": plan.get("title"), "text": copy.get("text")}


def _iso(value: Any) -> str | None:
    return value.isoformat() if hasattr(value, "isoformat") else None


def _reference_path(asset: dict[str, Any], uid: str, asset_id: str) -> str | None:
    path = asset.get("analysisPath")
    if isinstance(path, str) and path.startswith(f"uploads/{uid}/{asset_id}/"):
        return path
    return None


@https_fn.on_call(
    region="us-central1",
    memory=options.MemoryOption.MB_256,
    timeout_sec=20,
    max_instances=5,
    enforce_app_check=True,
)
def save_final_set(req: https_fn.CallableRequest) -> dict[str, Any]:
    """Save which of a slide's passed slides make up its final set, in order."""
    if req.auth is None:
        raise _fail(Code.UNAUTHENTICATED, "Sign in first.")
    data = _request_data(req)
    return run_save_final_set(
        uid=req.auth.uid,
        asset_id=data.get("assetId"),
        plan_ids=data.get("planIds"),
        db=firestore.client(),
    )


def run_save_final_set(uid: str, asset_id: Any, plan_ids: Any, db) -> dict[str, Any]:
    asset_ref, asset = _owned_asset(db, uid, asset_id)
    if (
        not isinstance(plan_ids, list)
        or not 1 <= len(plan_ids) <= MAX_PLANS
        or not all(isinstance(p, str) and PLAN_ID_PATTERN.match(p) for p in plan_ids)
        or len(set(plan_ids)) != len(plan_ids)
    ):
        raise _fail(Code.INVALID_ARGUMENT, f"Choose 1 to {MAX_PLANS} different slides.")
    if not asset.get("plans") or not asset.get("plansVersion"):
        raise _fail(Code.FAILED_PRECONDITION, "Save the plans first.")
    if not _plans_current(asset):
        raise _fail(
            Code.FAILED_PRECONDITION,
            "The blueprint changed since these plans were saved. Plan again.",
        )

    order = [plan.get("id") for plan in asset["plans"].get("plans") or []]
    slides = []
    for plan_id in plan_ids:
        if plan_id not in order:
            raise _fail(Code.NOT_FOUND, "This plan was not found.")
        slide = _passed_slide(asset_ref, asset, uid, asset_id, plan_id)
        if slide is None:
            raise _fail(
                Code.FAILED_PRECONDITION,
                f"Plan {order.index(plan_id) + 1} has no slide that passed its checks.",
            )
        slides.append(slide)

    version = int(asset.get("finalSetVersion") or 0) + 1
    asset_ref.update(
        {
            "finalSet": {
                "version": version,
                "slides": slides,
                "savedAt": firestore.SERVER_TIMESTAMP,
            },
            "finalSetVersion": version,
            "updatedAt": firestore.SERVER_TIMESTAMP,
        }
    )
    return {"assetId": asset_id, "finalSet": {"version": version, "slides": slides}}


@https_fn.on_call(
    region="us-central1",
    memory=options.MemoryOption.MB_256,
    timeout_sec=20,
    max_instances=5,
    enforce_app_check=True,
)
def list_slideshows(req: https_fn.CallableRequest) -> dict[str, Any]:
    """The caller's most recently updated references, for the Library."""
    if req.auth is None:
        raise _fail(Code.UNAUTHENTICATED, "Sign in first.")
    return run_list_slideshows(uid=req.auth.uid, db=firestore.client())


def _summary(asset_id: str, asset: dict[str, Any], uid: str) -> dict[str, Any]:
    """Counted from the asset alone; get_slideshow checks each slide properly."""
    variations, slides = asset.get("variations") or {}, asset.get("slides") or {}
    passed = sum(
        1
        for plan_id, variation in variations.items()
        if isinstance(variation, dict)
        and variation.get("status") == "passed"
        and variation.get("plansVersion") == asset.get("plansVersion")
        and (slides.get(plan_id) or {}).get("generationRunId") == variation.get("runId")
    )
    set_size = len((asset.get("finalSet") or {}).get("slides") or [])
    if set_size:
        stage = "set"
    elif passed:
        stage = "slides"
    elif asset.get("plans"):
        stage = "plans"
    elif asset.get("blueprint"):
        stage = "blueprint"
    elif asset.get("analysisStatus") == "ready":
        stage = "analysis"
    else:
        stage = "reference"
    return {
        "assetId": asset_id,
        "createdAt": _iso(asset.get("createdAt")),
        "updatedAt": _iso(asset.get("updatedAt")),
        "referencePath": _reference_path(asset, uid, asset_id),
        "stage": stage,
        "passedSlides": passed,
        "setSize": set_size,
    }


def run_list_slideshows(uid: str, db) -> dict[str, Any]:
    query = (
        db.collection("assets")
        .where(filter=firestore.FieldFilter("uid", "==", uid))
        .order_by("updatedAt", direction=firestore.Query.DESCENDING)
        .limit(LIBRARY_LIMIT)
    )
    summaries = []
    for snapshot in query.stream():
        asset = snapshot.to_dict() or {}
        if asset.get("uid") == uid and asset.get("status") == "ready":
            summaries.append(_summary(snapshot.id, asset, uid))
    return {"slideshows": summaries}


@https_fn.on_call(
    region="us-central1",
    memory=options.MemoryOption.MB_256,
    timeout_sec=20,
    max_instances=5,
    enforce_app_check=True,
)
def get_slideshow(req: https_fn.CallableRequest) -> dict[str, Any]:
    """One reference's saved set and passed slides, each checked again."""
    if req.auth is None:
        raise _fail(Code.UNAUTHENTICATED, "Sign in first.")
    data = _request_data(req)
    return run_get_slideshow(uid=req.auth.uid, asset_id=data.get("assetId"), db=firestore.client())


def run_get_slideshow(uid: str, asset_id: Any, db) -> dict[str, Any]:
    asset_ref, asset = _owned_asset(db, uid, asset_id)
    plans: list[dict[str, Any]] = []
    if _plans_current(asset):
        plans = [p for p in asset["plans"].get("plans") or [] if isinstance(p, dict)]
    details = {
        plan.get("id"): _plan_details(plan, index + 1) for index, plan in enumerate(plans)
    }

    passed = []
    for plan in plans:
        slide = _passed_slide(asset_ref, asset, uid, asset_id, plan.get("id"))
        if slide:
            passed.append({**slide, **details[plan.get("id")]})

    final_set = asset.get("finalSet") or None
    saved = None
    if final_set:
        prefix = f"uploads/{uid}/{asset_id}/slides/"
        kept = [
            {**entry, **details.get(entry.get("planId"), {})}
            for entry in final_set.get("slides") or []
            if isinstance(entry, dict)
            and str(entry.get("imagePath", "")).startswith(prefix)
            and _passed_run(asset_ref, uid, entry.get("generationRunId"))
        ]
        saved = {
            "version": final_set.get("version"),
            "savedAt": _iso(final_set.get("savedAt")),
            "slides": kept,
        }

    return {
        "assetId": asset_id,
        "createdAt": _iso(asset.get("createdAt")),
        "referencePath": _reference_path(asset, uid, asset_id),
        "finalSet": saved,
        "passedSlides": passed,
    }
