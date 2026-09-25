from __future__ import annotations

from collections import defaultdict
from pathlib import Path

from google import genai
from PIL import Image

from .graph_extraction import analyze_slideshow
from .models import SlideGraph, SlideshowAnalysis, VerificationResult
from .permission_filter import allowed_edits, filter_edits
from .scoped_edit import default_proposals_for_graph, run_variation_edit, save_image
from .verification import choose_output, restore_locked_ink, verify_locked_regions


IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp"}


def discover_slides(root: Path) -> list[Path]:
    return sorted(
        path
        for path in root.rglob("*")
        if path.is_file() and path.suffix.lower() in IMAGE_SUFFIXES
    )


def group_carousels(paths: list[Path]) -> dict[Path, list[Path]]:
    groups: dict[Path, list[Path]] = defaultdict(list)
    for path in paths:
        groups[path.parent].append(path)
    return {folder: sorted(slides) for folder, slides in sorted(groups.items())}


def run_slide(
    image_path: Path,
    output_dir: Path,
    graph: SlideGraph,
    analysis: SlideshowAnalysis | None = None,
) -> dict:
    output_dir.mkdir(parents=True, exist_ok=True)
    original = Image.open(image_path).convert("RGB")

    proposals = default_proposals_for_graph(graph)
    filtered = filter_edits(graph, proposals)
    allowed = allowed_edits(filtered)

    edited = None
    verification: VerificationResult | None = None
    shipped = original
    skip_reason = None
    if allowed:
        result = run_variation_edit(
            original,
            image_path,
            allowed,
            graph,
            analysis,
        )
        skip_reason = result.skip_reason
        if result.prompt:
            (output_dir / f"{graph.slide_id}_edit_prompt.txt").write_text(
                result.prompt
            )
        if result.skipped:
            shipped = original
        else:
            edited = restore_locked_ink(original, result.image, graph)
            save_image(edited, output_dir / f"{graph.slide_id}_edited.png")
            verification = verify_locked_regions(original, edited, graph)
            shipped = choose_output(original, edited, verification)
    else:
        skip_reason = "no eligible edit after filter"
    save_image(shipped, output_dir / f"{graph.slide_id}_shipped.png")
    if skip_reason and edited is None:
        stale = output_dir / f"{graph.slide_id}_edited.png"
        if stale.exists():
            stale.unlink()

    (output_dir / f"{graph.slide_id}_graph.json").write_text(
        graph.model_dump_json(indent=2)
    )

    return {
        "path": str(image_path),
        "graph": graph,
        "filtered": filtered,
        "allowed": allowed,
        "verification": verification,
        "skip_reason": skip_reason,
    }


def run_carousel(
    client: genai.Client,
    image_paths: list[Path],
    output_root: Path,
    ocr_texts: list[str] | None = None,
) -> tuple[SlideshowAnalysis, list[dict]]:
    """One analysis call for the carousel, then per-slide filtered edits."""
    analysis = analyze_slideshow(client, image_paths, ocr_texts=ocr_texts)
    output_root.mkdir(parents=True, exist_ok=True)
    (output_root / "_analysis.json").write_text(analysis.model_dump_json(indent=2))
    by_id = {slide.slide_id: slide for slide in analysis.slides}
    results = []
    for path in image_paths:
        graph = by_id[path.stem]
        results.append(
            run_slide(
                path,
                output_root / path.stem,
                graph=graph,
                analysis=analysis,
            )
        )
    return analysis, results
