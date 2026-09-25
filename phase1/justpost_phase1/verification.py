from __future__ import annotations

import numpy as np
from PIL import Image
from scipy.ndimage import binary_erosion
from skimage.metrics import structural_similarity

from .models import Element, ElementType, SlideGraph, VerificationResult, VerificationScore

# Prototype thresholds; replace with measured values from a representative set.
DEFAULT_MEAN_ABS_THRESHOLD = 6.0
DEFAULT_SSIM_THRESHOLD = 0.97
# A locked pixel is "ink" (UI/sticker) if it differs from the overlapping
# editable background's local border color by more than this (0–255 mean-abs).
INK_SEPARATION = 28.0
MIN_INK_PIXELS = 20
# Ink sitting on a replaced photo has anti-aliased edges. SSIM on a masked
# crop is a poor proxy for "does the button look the same," so ink-mask
# mode uses mean-abs only, with a slightly looser bar.
INK_MEAN_ABS_THRESHOLD = 16.0
# Do not stamp a full-frame "chrome" box — its ink mask can swallow the photo.
MAX_INK_RESTORE_AREA = 0.70
MAX_INK_RESTORE_FRACTION = 0.85
INK_RESTORE_TYPES = frozenset(
    {
        ElementType.TEXT,
        ElementType.UI_ELEMENT,
        ElementType.OVERLAY_GRAPHIC,
        ElementType.EMOJI,
        ElementType.ARROW,
    }
)


def _crop(image: Image.Image, element: Element) -> Image.Image:
    left, top, right, bottom = element.bbox.pixel_rect(*image.size)
    return image.crop((left, top, right, bottom))


def _array(image: Image.Image, element: Element) -> np.ndarray:
    return np.asarray(_crop(image, element).convert("RGB"), dtype=np.float32)


def _overlapping_backgrounds(graph: SlideGraph, locked: Element) -> list[Element]:
    return [
        other
        for other in graph.editable_elements()
        if other.type == ElementType.BACKGROUND and locked.bbox.overlaps(other.bbox)
    ]


def _ink_mask(locked_orig: np.ndarray, background_orig: np.ndarray) -> np.ndarray:
    """Pixels unlike the local photo around the locked box are UI ink.

    Using the whole background's median fails on colorful wallpapers (sky and
    water both look like 'ink'). The box border is almost always the photo
    sitting behind the sticker/button.
    """
    del background_orig
    height, width, _ = locked_orig.shape
    border = max(2, min(6, height // 8, width // 8))
    frame = np.concatenate(
        [
            locked_orig[:border].reshape(-1, 3),
            locked_orig[-border:].reshape(-1, 3),
            locked_orig[:, :border].reshape(-1, 3),
            locked_orig[:, -border:].reshape(-1, 3),
        ]
    )
    median = np.median(frame, axis=0)
    distance = np.mean(np.abs(locked_orig - median), axis=2)
    mask = distance > INK_SEPARATION
    # Drop the 1px fringe where the sticker is blended into the photo.
    if mask.any():
        eroded = binary_erosion(mask, iterations=1)
        if int(eroded.sum()) >= MIN_INK_PIXELS:
            mask = eroded
    return mask


def _masked_metrics(original: np.ndarray, edited: np.ndarray, mask: np.ndarray) -> tuple[float, float, float, int]:
    count = int(mask.sum())
    if count == 0:
        return 0.0, 0.0, 1.0, 0
    abs_diff = np.abs(original - edited)
    selected = abs_diff[mask]
    mean_abs = float(selected.mean())
    max_abs = float(selected.max())
    a = original.copy()
    b = edited.copy()
    a[~mask] = 0
    b[~mask] = 0
    win = min(7, original.shape[0], original.shape[1])
    if win < 3:
        ssim = 1.0 if mean_abs < 1e-6 else 0.0
    else:
        if win % 2 == 0:
            win -= 1
        ssim = float(
            structural_similarity(a, b, channel_axis=2, data_range=255.0, win_size=win)
        )
    return mean_abs, max_abs, ssim, count


def score_region(
    original: Image.Image,
    edited: Image.Image,
    element: Element,
    graph: SlideGraph | None = None,
) -> tuple[float, float, float, bool, int]:
    a = _array(original, element)
    b = _array(edited, element)
    if a.shape != b.shape:
        raise ValueError(f"region shape mismatch for {element.id}: {a.shape} vs {b.shape}")

    used_ink = False
    use_ink = element.type in INK_RESTORE_TYPES or (
        graph is not None and bool(_overlapping_backgrounds(graph, element))
    )
    if use_ink:
        bg = None
        if graph is not None:
            backgrounds = _overlapping_backgrounds(graph, element)
            if backgrounds:
                largest = max(backgrounds, key=lambda item: item.bbox.w * item.bbox.h)
                bg = _array(original, largest)
        mask = _ink_mask(a, bg if bg is not None else a)
        if int(mask.sum()) >= MIN_INK_PIXELS:
            mean_abs, max_abs, ssim, count = _masked_metrics(a, b, mask)
            return mean_abs, max_abs, ssim, True, count
        if graph is not None and _overlapping_backgrounds(graph, element):
            return 0.0, 0.0, 1.0, True, 0

    abs_diff = np.abs(a - b)
    mean_abs = float(abs_diff.mean())
    max_abs = float(abs_diff.max())
    win = min(7, a.shape[0], a.shape[1])
    if win < 3:
        ssim = 1.0 if mean_abs < 1e-6 else 0.0
    else:
        if win % 2 == 0:
            win -= 1
        ssim = float(
            structural_similarity(a, b, channel_axis=2, data_range=255.0, win_size=win)
        )
    return mean_abs, max_abs, ssim, used_ink, a.shape[0] * a.shape[1]


def restore_locked_ink(
    original: Image.Image,
    edited: Image.Image,
    graph: SlideGraph,
) -> Image.Image:
    """Copy original UI/caption ink onto the edited frame.

    The image model redraws the full slide. This puts locked sticker/button pixels back
    so a wallpaper swap cannot fail because Focus was slightly regenerated.
    Identity and brand marks are not stamped here — they stay full-box.
    """
    if edited.size != original.size:
        edited = edited.resize(original.size, Image.Resampling.LANCZOS)

    orig = np.asarray(original.convert("RGB"))
    out = np.asarray(edited.convert("RGB")).copy()

    for element in graph.locked_elements():
        if element.type not in INK_RESTORE_TYPES:
            continue
        if element.bbox.w * element.bbox.h >= MAX_INK_RESTORE_AREA:
            continue
        left, top, right, bottom = element.bbox.pixel_rect(*original.size)
        crop = orig[top:bottom, left:right].astype(np.float32)
        mask = _ink_mask(crop, crop)
        count = int(mask.sum())
        if count < MIN_INK_PIXELS:
            continue
        if count / mask.size > MAX_INK_RESTORE_FRACTION:
            continue
        dest = out[top:bottom, left:right]
        dest[mask] = orig[top:bottom, left:right][mask]
        out[top:bottom, left:right] = dest

    return Image.fromarray(out)


def verify_locked_regions(
    original: Image.Image,
    edited: Image.Image,
    graph: SlideGraph,
    mean_abs_threshold: float = DEFAULT_MEAN_ABS_THRESHOLD,
    ssim_threshold: float = DEFAULT_SSIM_THRESHOLD,
) -> VerificationResult:
    if edited.size != original.size:
        edited = edited.resize(original.size, Image.Resampling.LANCZOS)

    scores: list[VerificationScore] = []
    for element in graph.locked_elements():
        mean_abs, max_abs, ssim, used_ink, count = score_region(
            original, edited, element, graph
        )
        if used_ink:
            passed = mean_abs <= INK_MEAN_ABS_THRESHOLD
        else:
            passed = mean_abs <= mean_abs_threshold and ssim >= ssim_threshold
        scores.append(
            VerificationScore(
                element_id=element.id,
                role=element.role,
                mean_abs=mean_abs,
                max_abs=max_abs,
                ssim=ssim,
                passed=passed,
                used_ink_mask=used_ink,
                compared_pixels=count,
            )
        )

    all_passed = all(item.passed for item in scores) if scores else True
    return VerificationResult(
        passed=all_passed,
        scores=scores,
        mean_abs_threshold=mean_abs_threshold,
        ssim_threshold=ssim_threshold,
        fallback_to_original=not all_passed,
    )


def choose_output(original: Image.Image, edited: Image.Image, result: VerificationResult) -> Image.Image:
    """Failed verification ships the unedited original, never a guess."""
    return original if result.fallback_to_original else edited
