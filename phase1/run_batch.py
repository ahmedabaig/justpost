from __future__ import annotations

import json
import os
import sys
import time
import traceback
from pathlib import Path

from dotenv import load_dotenv
from google import genai

ROOT = Path(__file__).resolve().parent
load_dotenv(ROOT / ".env")
sys.path.insert(0, str(ROOT))

from justpost_phase1.pipeline import discover_slides, group_carousels, run_carousel


def summarize(result: dict) -> dict:
    graph = result["graph"]
    verification = result["verification"]
    return {
        "path": result["path"],
        "slide_id": graph.slide_id,
        "format": None if graph.format is None else graph.format.model_dump(),
        "elements": [
            {
                "id": e.id,
                "type": e.type.value,
                "role": e.role.value,
                "editable": e.permissions.editable,
                "label": e.label,
                "points_to": e.points_to,
                "anchors_to": e.anchors_to,
                "editable_attributes": e.editable_attributes,
                "locked_attributes": e.locked_attributes,
            }
            for e in graph.elements
        ],
        "allowed_edit": (
            result["allowed"][0].proposal.element_id if result["allowed"] else None
        ),
        "skip_reason": result.get("skip_reason"),
        "verification_passed": None if verification is None else verification.passed,
        "fallback_to_original": None
        if verification is None
        else verification.fallback_to_original,
        "locked_scores": []
        if verification is None
        else [
            {
                "element_id": s.element_id,
                "role": s.role.value,
                "mean_abs": round(s.mean_abs, 2),
                "max_abs": round(s.max_abs, 1),
                "ssim": round(s.ssim, 4),
                "passed": s.passed,
            }
            for s in verification.scores
        ],
        "error": None,
    }


def main() -> int:
    if not os.environ.get("GEMINI_API_KEY"):
        print("GEMINI_API_KEY missing in phase1/.env")
        return 1
    if not os.environ.get("OPENAI_API_KEY"):
        print("OPENAI_API_KEY missing in phase1/.env")
        return 1

    slides_root = ROOT / "slideshows"
    only = sys.argv[1:]
    paths = discover_slides(slides_root)
    if only:
        paths = [
            p
            for p in paths
            if any(token in str(p) or token == p.parent.name for token in only)
        ]

    groups = group_carousels(paths)
    print(f"running {len(paths)} slides in {len(groups)} carousel(s)")
    client = genai.Client()
    rows = []
    done = 0
    for folder, slides in groups.items():
        print(f"analyze {folder.name} ({len(slides)} slides)", flush=True)
        try:
            analysis, results = run_carousel(
                client, slides, ROOT / "outputs" / folder.name
            )
            print(
                "  hook=",
                analysis.format.hook_mechanic,
                " pacing=",
                analysis.format.pacing,
                flush=True,
            )
            for result in results:
                done += 1
                row = summarize(result)
                print(
                    f"  [{done}/{len(paths)}]",
                    Path(row["path"]).name,
                    " allowed=",
                    row["allowed_edit"],
                    " verify=",
                    row["verification_passed"],
                    flush=True,
                )
                rows.append(row)
        except Exception as exc:
            print("  ERROR", f"{type(exc).__name__}: {exc}", flush=True)
            traceback.print_exc()
            for path in slides:
                rows.append(
                    {
                        "path": str(path),
                        "slide_id": path.stem,
                        "error": f"{type(exc).__name__}: {exc}",
                    }
                )
        time.sleep(1)

    summary_path = ROOT / "outputs" / "batch_summary.json"
    summary_path.parent.mkdir(parents=True, exist_ok=True)
    summary_path.write_text(json.dumps(rows, indent=2))
    ok = sum(1 for r in rows if not r.get("error"))
    print(f"wrote {summary_path} ({ok}/{len(rows)} ok)")
    return 0 if ok == len(rows) else 2


if __name__ == "__main__":
    raise SystemExit(main())
