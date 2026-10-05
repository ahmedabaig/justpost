from io import BytesIO

import pytest
from PIL import Image, ImageCms

from justpost import ingest
from justpost.ingest import IngestError, ingest_image, orientation_for


def _encode(image: Image.Image, fmt: str, **params) -> bytes:
    buffer = BytesIO()
    image.save(buffer, fmt, **params)
    return buffer.getvalue()


def _two_tone(width: int = 40, height: int = 20) -> Image.Image:
    """Left half red, right half blue."""
    image = Image.new("RGB", (width, height), "blue")
    image.paste((255, 0, 0), (0, 0, width // 2, height))
    return image


def _decode(data: bytes) -> Image.Image:
    image = Image.open(BytesIO(data))
    image.load()
    return image


def test_exif_rotation_is_applied_to_both_copies():
    exif = Image.Exif()
    exif[0x0112] = 6  # rotate 90 degrees clockwise to display
    data = _encode(_two_tone(), "JPEG", exif=exif, quality=95)

    result = ingest_image(data)

    assert result.exif_orientation == 6
    assert (result.source_width, result.source_height) == (40, 20)
    assert (result.width, result.height) == (20, 40)
    assert result.orientation == "portrait"
    working = _decode(result.working_png)
    assert working.size == (20, 40)
    red, green, blue = working.convert("RGB").getpixel((10, 2))
    assert red > 200 and blue < 60, "the original left edge should now be on top"


def test_derived_copies_carry_no_exif():
    exif = Image.Exif()
    exif[0x0112] = 1
    exif[0x010F] = "Camera maker"
    data = _encode(_two_tone(), "JPEG", exif=exif)

    result = ingest_image(data)

    assert len(_decode(result.working_png).getexif()) == 0
    assert len(_decode(result.analysis_webp).getexif()) == 0


def test_transparency_is_kept_in_working_and_flattened_in_analysis():
    image = Image.new("RGBA", (30, 30), (0, 0, 0, 0))
    image.paste((255, 0, 0, 255), (10, 10, 20, 20))

    result = ingest_image(_encode(image, "PNG"))

    assert result.has_alpha is True
    working = _decode(result.working_png)
    assert working.mode == "RGBA"
    assert working.getpixel((0, 0))[3] == 0
    analysis = _decode(result.analysis_webp).convert("RGB")
    assert all(channel > 240 for channel in analysis.getpixel((0, 0)))


def test_heic_is_supported():
    data = _encode(_two_tone(64, 128), "HEIF", quality=90)

    result = ingest_image(data)

    assert result.source_format == "HEIF"
    assert result.mime_type.startswith("image/hei")
    assert (result.width, result.height) == (64, 128)
    assert _decode(result.working_png).mode == "RGB"


def test_cmyk_jpeg_becomes_rgb():
    image = Image.new("CMYK", (16, 16), (0, 255, 255, 0))  # red in CMYK

    result = ingest_image(_encode(image, "JPEG"))

    working = _decode(result.working_png)
    assert working.mode == "RGB"
    red, green, blue = working.getpixel((8, 8))
    assert red > 150 and green < 100 and blue < 100


def test_embedded_profile_is_recorded_and_converted():
    srgb = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    data = _encode(_two_tone(), "PNG", icc_profile=srgb)

    result = ingest_image(data)

    assert result.color_profile is not None
    assert "sRGB" in result.color_profile
    assert _decode(result.working_png).mode == "RGB"


def test_images_without_a_profile_report_none():
    assert ingest_image(_encode(_two_tone(), "PNG")).color_profile is None


def test_analysis_copy_is_downscaled_to_the_long_side_limit():
    result = ingest_image(_encode(Image.new("RGB", (3000, 1000), "gray"), "JPEG"))

    assert (result.width, result.height) == (3000, 1000)
    assert _decode(result.analysis_webp).size == (1536, 512)


def test_small_images_are_not_upscaled_for_analysis():
    result = ingest_image(_encode(Image.new("RGB", (300, 600), "gray"), "PNG"))

    assert _decode(result.analysis_webp).size == (300, 600)


def test_non_images_are_rejected():
    with pytest.raises(IngestError):
        ingest_image(b"definitely not an image")


def test_truncated_images_are_rejected():
    data = _encode(Image.new("RGB", (200, 200), "gray"), "JPEG")
    with pytest.raises(IngestError):
        ingest_image(data[: len(data) // 3])


def test_unsupported_formats_are_rejected():
    with pytest.raises(IngestError):
        ingest_image(_encode(Image.new("RGB", (10, 10)), "GIF"))


def test_oversized_images_are_rejected(monkeypatch):
    monkeypatch.setattr(ingest, "MAX_PIXELS", 100)
    with pytest.raises(IngestError):
        ingest_image(_encode(Image.new("RGB", (20, 20)), "PNG"))


@pytest.mark.parametrize(
    ("size", "expected"),
    [((1179, 2556), "portrait"), ((1920, 1080), "landscape"), ((1000, 1010), "square")],
)
def test_orientation_labels(size, expected):
    assert orientation_for(*size) == expected
