from .models import (
    BBox,
    EditRole,
    ElementType,
    ExtractedElement,
    FilteredEdit,
    FormatSpec,
    ProposedEdit,
    SlideshowAnalysis,
)
from .policy import apply_permissions
from .scoped_edit import (
    build_variation_prompt,
    default_proposals_for_graph,
    openai_size_label,
)


def test_portrait_maps_to_openai_portrait_size():
    assert openai_size_label(768, 1024) == "1024x1536"
    assert openai_size_label(1024, 1024) == "1024x1024"
    assert openai_size_label(1920, 1080) == "1536x1024"

def test_prompt_distills_analysis_graph_and_only_allowed_changes():
    graph = apply_permissions(
        slide_id="slide-a",
        source_path="a.jpg",
        width_px=100,
        height_px=100,
        extracted=[
            ExtractedElement(
                id="bg",
                type=ElementType.BACKGROUND,
                role=EditRole.EDITABLE,
                bbox=BBox(x=0.0, y=0.0, w=1.0, h=1.0),
                label="sunset wallpaper",
            ),
            ExtractedElement(
                id="caption",
                type=ElementType.TEXT,
                role=EditRole.PROTECTED,
                bbox=BBox(x=0.2, y=0.7, w=0.6, h=0.1),
                label="hook",
                text="Click add widgets",
            ),
        ],
    )
    analysis = SlideshowAnalysis(
        format=FormatSpec(
            hook_mechanic="stated_benefit",
            slide_count=2,
            pacing="step_by_step_tutorial",
        ),
        slides=[graph],
    )
    bg = next(e for e in graph.elements if e.id == "bg")
    allowed = [
        FilteredEdit(
            proposal=ProposedEdit(
                element_id="bg",
                instruction="Shift the wallpaper color slightly.",
            ),
            allowed=True,
            reason="ok",
            element=bg,
        )
    ]
    prompt = build_variation_prompt(graph, allowed, analysis)
    assert "SLIDESHOW ROLE" in prompt
    assert "stated_benefit" in prompt
    assert "Click add widgets" in prompt
    assert "Shift the wallpaper color slightly." in prompt
    assert "source_path" not in prompt
    assert "bbox" not in prompt
    assert '"slide_id"' not in prompt
    assert len(prompt.splitlines()) < 30
    change_block = prompt.split("CHANGE ONLY")[-1]
    assert "sunset wallpaper" in change_block
    assert "Click add widgets" not in change_block


def test_default_proposals_include_full_frame_background():
    graph = apply_permissions(
        slide_id="t",
        source_path="t.jpg",
        width_px=100,
        height_px=100,
        extracted=[
            ExtractedElement(
                id="bg",
                type=ElementType.BACKGROUND,
                role=EditRole.EDITABLE,
                bbox=BBox(x=0.0, y=0.0, w=1.0, h=1.0),
                label="screenshot wallpaper",
            ),
        ],
    )
    ids = [item.element_id for item in default_proposals_for_graph(graph)]
    assert ids == ["bg"]
