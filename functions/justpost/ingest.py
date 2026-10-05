"""Phase 1: turn an uploaded reference slide into stable internal assets.

This module only processes bytes. It does not decide why a creative works.
"""

from __future__ import annotations

from dataclasses import dataclass
from io import BytesIO

import pillow_heif
from PIL import Image, ImageCms, ImageOps, UnidentifiedImageError

pillow_heif.register_heif_opener()

ALLOWED_FORMATS = frozenset({"JPEG", "PNG", "WEBP", "HEIF"})
# Guards against decompression bombs; a 48MP camera photo is well under this.
MAX_PIXELS = 60_000_000
ANALYSIS_LONG_SIDE = 1536
ANALYSIS_QUALITY = 85
SQUARE_TOLERANCE = 0.02

_SRGB = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB"))


class IngestError(ValueError):
    """The upload cannot be used as a reference slide."""


@dataclass(frozen=True)
class IngestResult:
    working_png: bytes
    analysis_webp: bytes
    width: int
    height: int
    orientation: str
    source_format: str
    mime_type: str
    source_width: int
    source_height: int
    exif_orientation: int
    has_alpha: bool
    color_profile: str | None


def orientation_for(width: int, height: int) -> str:
    if abs(width - height) <= SQUARE_TOLERANCE * max(width, height):
        return "square"
    return "portrait" if height > width else "landscape"


def _open(data: bytes) -> Image.Image:
    try:
        image = Image.open(BytesIO(data))
    except (UnidentifiedImageError, Image.DecompressionBombError, OSError) as error:
        raise IngestError("Not a supported image.") from error
    if image.format not in ALLOWED_FORMATS:
        raise IngestError(f"Unsupported image format: {image.format}.")
    width, height = image.size
    if width * height > MAX_PIXELS:
        raise IngestError("Image is too large.")
    try:
        image.load()
    except (OSError, Image.DecompressionBombError) as error:
        raise IngestError("Image could not be decoded.") from error
    return image


def _has_alpha(image: Image.Image) -> bool:
    return image.mode in {"RGBA", "LA", "PA"} or (
        image.mode == "P" and "transparency" in image.info
    )


def _profile_name(icc: bytes | None) -> str | None:
    if not icc:
        return None
    try:
        name = ImageCms.getProfileDescription(ImageCms.ImageCmsProfile(BytesIO(icc)))
    except (ImageCms.PyCMSError, OSError):
        return "unknown"
    return name.strip() or "unknown"


def _to_srgb(image: Image.Image, icc: bytes | None) -> Image.Image:
    """Returns an RGB image in sRGB, honouring an embedded profile when present."""
    if icc:
        try:
            source = ImageCms.ImageCmsProfile(BytesIO(icc))
            return ImageCms.profileToProfile(image, source, _SRGB, outputMode="RGB")
        except (ImageCms.PyCMSError, OSError, ValueError):
            pass
    return image.convert("RGB")


def _encode(image: Image.Image, fmt: str, **params) -> bytes:
    buffer = BytesIO()
    image.save(buffer, fmt, **params)
    return buffer.getvalue()


def ingest_image(data: bytes) -> IngestResult:
    image = _open(data)
    source_format = image.format
    source_width, source_height = image.size
    exif_orientation = int(image.getexif().get(0x0112, 1) or 1)
    icc = image.info.get("icc_profile")
    has_alpha = _has_alpha(image)

    upright = ImageOps.exif_transpose(image)

    if upright.mode in {"P", "PA"}:
        upright = upright.convert("RGBA" if has_alpha else "RGB")
    alpha = None
    if upright.mode in {"RGBA", "LA"}:
        alpha = upright.getchannel("A")
        upright = upright.convert("RGB" if upright.mode == "RGBA" else "L")

    working = _to_srgb(upright, icc)
    if alpha is not None:
        working.putalpha(alpha)

    if alpha is not None:
        analysis = Image.new("RGB", working.size, "white")
        analysis.paste(working, mask=alpha)
    else:
        analysis = working.copy()
    analysis.thumbnail(
        (ANALYSIS_LONG_SIDE, ANALYSIS_LONG_SIDE), Image.Resampling.LANCZOS
    )

    width, height = working.size
    return IngestResult(
        working_png=_encode(working, "PNG", compress_level=6),
        analysis_webp=_encode(analysis, "WEBP", quality=ANALYSIS_QUALITY),
        width=width,
        height=height,
        orientation=orientation_for(width, height),
        source_format=source_format,
        mime_type=Image.MIME.get(source_format, "application/octet-stream"),
        source_width=source_width,
        source_height=source_height,
        exif_orientation=exif_orientation,
        has_alpha=has_alpha,
        color_profile=_profile_name(icc),
    )
