# JustPost V1 Backend Plan: From One Winning Slide to Multiple Variations

> **Purpose of this document**
>
> This document describes a proposed V1 backend architecture for JustPost: a system that accepts a high-performing social-media slide as a reference and produces multiple new variations that preserve the original creative principles without simply duplicating the source.
>
> The examples in this document — including JSON outputs, prompts, field names, scores, and thresholds — are **illustrative examples only**. They are **not templates, production-ready schemas, or fixed prompt wording**. The purpose is to make each phase concrete and easy to reason about.

---

## 1. High-Level Goal

The core V1 user experience should be extremely simple:

1. The user uploads one reference slide.
2. JustPost analyzes why that slide works.
3. JustPost creates multiple distinct variation plans.
4. JustPost generates new images from those plans.
5. JustPost renders copy and overlays separately when appropriate.
6. JustPost validates each result.
7. JustPost retries or removes weak outputs.
8. The user receives a set of high-quality variations.

The system should **not** rely on a single prompt like:

> "Make 10 variations of this image."

That approach gives too much control to the image-generation model and often produces:
- near-duplicates,
- inconsistent changes,
- loss of the original creative format,
- accidental changes to important elements,
- poor text rendering,
- weak diversity across outputs.

Instead, JustPost should separate the task into distinct phases.

---

# 2. Canonical V1 Pipeline

```text
User uploads winning slide
↓
1. Ingest + normalize image
↓
2. Analyze creative structure
↓
3. Build canonical creative blueprint
↓
4. Generate N variation plans
↓
5. Create images from each plan
↓
6. Render text/overlays separately
↓
7. Validate against blueprint
↓
8. (Optional) Retry / filter / deduplicate failed outputs
↓
9. Return final set
```


## Multimodal architecture note

This document describes **JustPost's product-level phases**, not the internal neural-network phases of the model provider.

For a modern OpenAI-style implementation, the safer product-level mental model is:

```text
reference image
+
analysis instructions
↓
multimodal model
↓
structured creative analysis
```

JustPost should **not** assume that it needs to build or manage a separate vision encoder and then manually pass a visual feature vector into a text-only LLM.

There may still be modality-specific processing inside the provider's model, but that internal implementation is not something JustPost needs to reproduce, expose, or depend on.

The important distinction is:

- **Model-internal representation:** how the provider's multimodal model numerically represents and reasons over visual information.
- **JustPost creative blueprint:** the structured product-level representation JustPost creates so it can control what should remain conceptually stable, what may vary, how variations are planned, and how outputs are validated.

These are different layers and should remain separate.

Each stage has one job.

That separation is important because it makes the system:
- easier to debug,
- easier to improve,
- easier to test,
- easier to control,
- more consistent across different types of creative.

---

# 3. Phase 1 — Ingest and Normalize the Image

## Objective

Accept the user-uploaded image and convert it into a stable internal asset that downstream services can reliably consume.

At this phase, JustPost should **not yet decide why the creative works**.

This is an asset-processing step.

## Inputs

Typical input:

```text
user_upload.jpg
```

Potential metadata available at upload time:
- file type,
- width,
- height,
- file size,
- orientation,
- alpha/transparency,
- color profile.

## Backend actions

The backend should generally:

1. Store the original upload.
2. Generate an internal asset ID.
3. Read dimensions and orientation.
4. Normalize orientation.
5. Create a working copy if needed.
6. Optionally create a lower-resolution analysis copy.
7. Preserve the original image for later image-generation/editing requests.

## Example internal asset record

> Example only — not a required schema.

```json
{
  "asset_id": "img_01JPOST123",
  "original_url": "s3://justpost/uploads/img_01JPOST123.jpg",
  "analysis_url": "s3://justpost/analysis/img_01JPOST123.webp",
  "width": 1179,
  "height": 2556,
  "mime_type": "image/jpeg",
  "orientation": "portrait",
  "status": "ready"
}
```

## Why normalization matters

Different uploads may arrive as:
- JPEG,
- PNG,
- HEIC,
- WebP,
- screenshots,
- exported TikTok slides,
- compressed social-media images.

You do not want each downstream model call to handle these inconsistencies independently.

The ingestion service should create a predictable representation.

---

# 4. Phase 2 — Analyze Creative Structure

## Objective

Understand what is present in the slide and what creative mechanisms it appears to use.

This phase asks:

> "What is this image doing?"

JustPost sends the reference image and the analysis instructions together to a multimodal model. The model reasons over the visual content and the textual instruction in the same request and returns structured creative analysis.

It should **not yet decide the final preservation/change policy**.

That is the next phase.

## Important distinction

### Analysis is observation.

For example:

```text
- subject is seated inside a car
- subject is wearing an olive hijab
- subject's face is covered by a pink heart
- subject is holding a green drink
- large text appears in the lower-middle area
- copy uses a how-to hook
- image has casual UGC/selfie aesthetics
```

This is different from deciding:

```text
- car setting must be preserved
- hijab color may vary
- face must remain obscured
```

The first is **analysis**.

The second is **creative policy / blueprint construction**.

## Model input

A multimodal model receives:
- the reference image,
- instructions explaining that the purpose is variation generation,
- a structured-output requirement.

For an OpenAI-style implementation, this is conceptually:

```text
reference image + text instructions
↓
multimodal model
↓
structured JSON analysis
```

JustPost does **not** need to create its own image embeddings or manually fuse image features with language before making this call.

## Example analysis system instruction

> **Example only. Do not treat this as a production template.**

```text
You are analyzing a social-media slide so that another system can create high-quality creative variations from it.

Describe the creative structure of the image rather than merely captioning it.

Identify:
- scene and environment,
- subject and styling,
- composition and framing,
- major visual devices,
- visible copy and its role,
- hook type,
- likely creative objective,
- visual hierarchy,
- aesthetic style,
- notable objects,
- relationships between objects,
- which elements appear central to the creative idea.

Return structured JSON.

Do not decide final mutation rules yet. Focus on accurate observation and creative interpretation.
```

## Example analysis output

> Example only.

```json
{
  "creative_type": "ugc_hook_slide",
  "scene": {
    "environment": "car interior",
    "lighting": "natural daylight",
    "background": "urban street visible outside",
    "camera_style": "casual front-facing social-media photo"
  },
  "subject": {
    "presentation": "modest Muslim female creator",
    "position": "center-right",
    "head_covering": {
      "present": true,
      "color": "olive green"
    },
    "face_visibility": "obscured",
    "holding": "green beverage"
  },
  "visual_devices": [
    {
      "type": "graphic_overlay",
      "description": "large pink heart covering the subject's face",
      "role": "privacy and casual UGC styling"
    }
  ],
  "copy": {
    "primary_text": "Here's how to add the 99 Names of Allah on your lock screen",
    "secondary_text": "(that changes every day)",
    "hook_type": "how-to",
    "mechanisms": [
      "specific utility",
      "religious relevance",
      "daily novelty"
    ]
  },
  "composition": {
    "orientation": "portrait",
    "subject_weight": "central",
    "text_position": "lower-middle",
    "visual_hierarchy": [
      "subject",
      "heart graphic",
      "hook text",
      "environment"
    ]
  },
  "aesthetic": [
    "UGC",
    "casual",
    "aspirational",
    "mobile-native"
  ]
}
```

## What this phase should avoid

The analysis model should not invent rules like:

```text
"the hijab must never change"
```

unless those rules are provided externally.

Its job is to understand.

---

# 5. Phase 3 — Build the Canonical Creative Blueprint

## Objective

Convert the raw creative analysis into JustPost's internal definition of:

> "What must remain true for a future output to still belong to this winning creative family?"

This is one of the most important phases.

The blueprint is **not an exhaustive image description**.

It is a compressed representation of the creative's functional DNA.

## Why this phase should be separate from analysis

An image may contain hundreds of observable details.

Not all of them matter.

For example:

```text
Observation:
The cup is green.

Question:
Does "green cup" make the creative work?

Probably not.
```

Meanwhile:

```text
Observation:
The person's face is hidden by a graphic.

Question:
Does face concealment contribute to the creative format?

Possibly yes.
```

The blueprint converts observations into:
- invariants,
- variable dimensions,
- creative roles,
- structural constraints.

## Example blueprint

> Example only.

```json
{
  "blueprint_version": "1.0",
  "creative_family": "ugc_car_selfie_hook",
  "objective": "introduce an Islamic lock-screen feature through a casual UGC-style hook",
  "required_principles": [
    "portrait social-media composition",
    "modest Muslim female creator",
    "creator positioned inside a car",
    "face is intentionally obscured",
    "casual UGC/selfie aesthetic",
    "large readable hook copy",
    "image feels natural rather than studio-produced"
  ],
  "preferred_principles": [
    "beverage in hand",
    "natural daylight",
    "aspirational car interior",
    "simple face-cover graphic"
  ],
  "variation_dimensions": [
    "hijab color",
    "beverage type",
    "face-cover graphic",
    "pose",
    "car interior styling",
    "hook wording",
    "minor background detail"
  ],
  "copy_strategy": {
    "role": "hook",
    "primary_pattern": "show or explain a concrete Islamic utility",
    "secondary_pattern": "add curiosity or recurring value"
  },
  "forbidden_drift": [
    "turning the scene into a studio advertisement",
    "removing modest styling",
    "making the face fully prominent",
    "losing the car/selfie context",
    "making the slide feel like unrelated stock photography"
  ]
}
```

## The blueprint should be stable

Once created, store it.

You should not need to re-analyze the same source image every time the user requests more variations.

For example:

```text
Reference image
↓
Analysis
↓
Blueprint
↓
Saved
```

Later:

```text
Saved blueprint
↓
"Generate 5 more"
↓
New variation plans
```

This saves:
- latency,
- model cost,
- inconsistency.

---

# 6. Phase 4 — Generate N Variation Plans

## Objective

Create multiple intentional creative directions **before** calling the image-generation model.

This phase answers:

> "Exactly how will variation #1 differ from variation #2?"

No images should be generated yet.

## Why planning comes before image generation

If you simply request eight generations from one prompt, the model may produce near-duplicates.

The variation planner gives the system explicit creative diversity.

## Inputs

The planning model receives:
- canonical blueprint,
- number of desired variations,
- optionally previous variation plans,
- optionally a diversity policy.

## Example planning instruction

> **Example only.**

```text
Create 8 distinct variation plans for this creative blueprint.

Every plan must preserve the required creative principles.

Vary only dimensions that are allowed by the blueprint.

The outputs should feel like members of the same winning creative family, but they should not be near-duplicates.

Distribute variation across:
- subject styling,
- face-cover graphic,
- beverage,
- pose,
- environment details,
- hook wording.

Avoid changing every variable at once unless doing so still clearly preserves the creative format.

Return structured JSON only.
```

## Example variation-plan output

> Example only.

```json
[
  {
    "variation_id": "v1",
    "visual_changes": {
      "hijab_color": "warm cream",
      "beverage": "iced coffee",
      "face_cover": "muted beige heart",
      "pose": "slightly turned toward passenger window",
      "car_interior": "brown leather"
    },
    "copy": {
      "hook_type": "POV",
      "hook_text": "POV: your lock screen teaches you a new Name of Allah every day"
    }
  },
  {
    "variation_id": "v2",
    "visual_changes": {
      "hijab_color": "black",
      "beverage": "matcha",
      "face_cover": "small white flower graphic",
      "pose": "looking slightly downward",
      "car_interior": "dark leather"
    },
    "copy": {
      "hook_type": "how_to",
      "hook_text": "How to put the 99 Names of Allah on your lock screen"
    }
  }
]
```

## Variation strength

Eventually you may want:
- low variation,
- medium variation,
- high variation.

For V1, this can remain internal.

Illustratively:

### Low
- same environment,
- similar framing,
- minor color/object changes.

### Medium
- same format,
- altered styling, pose, and scene details.

### High
- same creative principles,
- more substantial visual and copy differences.

This does not need to be user-facing in V1.

---

# 7. Phase 5 — Create Images From Each Plan

## Objective

Generate a new visual for each variation plan while preserving the source creative's underlying principles.

## Inputs

Each generation request can receive:
- original reference image,
- canonical blueprint,
- one specific variation plan,
- generation instructions.

## Important conceptual distinction

The image model should **not** receive only:

```text
"Make a variation."
```

It should receive:
1. what must stay conceptually true,
2. what this variation should change,
3. what kind of output is desired.

## Example generation instruction

> **Example only — not a fixed template.**

```text
Use the provided image as a creative reference, not as something to copy pixel-for-pixel.

Create a new vertical UGC-style social-media image that preserves these creative principles:

- modest Muslim female creator
- seated inside a car
- casual selfie aesthetic
- natural daylight
- face intentionally obscured by a playful graphic
- mobile-native, organic appearance
- subject remains the main visual focus

For this variation:

- use a warm cream hijab
- use a brown leather car interior
- show an iced coffee
- use a muted beige heart to obscure the face
- slightly turn the subject toward the passenger-side window

The output should clearly belong to the same creative family as the reference while looking visually distinct.

Do not include marketing text in the generated image.
Do not make the result look like polished studio advertising.
```

## Why the reference image should still be included

Even though you have a blueprint, the source image contains nuance that is difficult to serialize:
- visual vibe,
- camera perspective,
- realism level,
- composition balance,
- lighting,
- subject scale,
- visual texture,
- aesthetic nuance.

The blueprint provides **control**.

The image provides **visual context**.

Use both.

---

# 8. Phase 6 — Render Text and Overlays Separately

## Objective

Keep typography and important overlays deterministic whenever possible.

## Why not let image generation handle all text?

Generative image models can:
- misspell words,
- change punctuation,
- produce inconsistent fonts,
- alter line breaks,
- distort text,
- accidentally modify copy between outputs.

For a content-generation product, this is avoidable.

## Recommended layer structure

```text
FINAL SLIDE
│
├── generated photographic visual
│
├── hook text layer
│
├── subtitle layer
│
├── sticker / graphic layer
│
└── branding layer, if applicable
```

You may decide whether certain simple overlays — such as a heart covering a face — should be:
- generated into the visual,
- or composited as a separate layer.

For V1, either is valid.

Text should generally be separate.

## Example render specification

> Example only.

```json
{
  "canvas": {
    "width": 1179,
    "height": 2556
  },
  "text_layers": [
    {
      "role": "hook",
      "text": "POV: your lock screen teaches you a new Name of Allah every day",
      "position": {
        "x": 590,
        "y": 1750
      },
      "max_width": 900,
      "alignment": "center",
      "font_role": "ugc_bold",
      "background_style": "white_rounded_box"
    }
  ]
}
```

## Rendering engine options

Implementation could eventually use:
- native iOS rendering,
- Skia,
- Canvas,
- server-side image composition,
- Core Graphics,
- another deterministic graphics pipeline.

The specific technology is less important than the principle:

> Generative systems create uncertain creative content. Deterministic systems should handle exact typography and layout whenever possible.

---

# 9. Phase 7 — Validate Against the Blueprint

## Objective

Check whether the generated output still satisfies the creative family.

Generation should not automatically equal acceptance.

## Validation questions

The system can ask:
- Is the subject still inside a car?
- Is the subject modestly styled?
- Is the face still obscured?
- Does the visual still look like UGC?
- Is the requested beverage present?
- Did the image drift into a different format?
- Did the model produce major artifacts?
- Is the subject positioned correctly?
- Does the generation match the requested variation plan?

## Example validation system instruction

> **Example only.**

```text
Evaluate the generated image against the supplied creative blueprint and variation plan.

Do not judge whether you personally like the image.

Check whether:
- required creative principles are present,
- requested variation changes were followed,
- forbidden creative drift occurred,
- the output appears visually coherent,
- the output remains recognizably part of the intended creative family.

Return structured results and identify any hard failures.
```

## Example output

> Example only.

```json
{
  "variation_id": "v4",
  "valid": false,
  "hard_failures": [
    "subject face is fully visible"
  ],
  "checks": {
    "car_environment": true,
    "modest_subject": true,
    "face_obscured": false,
    "ugc_aesthetic": true,
    "requested_hijab_color": true,
    "requested_beverage": true
  },
  "quality_score": 0.84,
  "blueprint_match_score": 0.71
}
```

---

# 10. Phase 8 — Optional Retry, Filter, and Deduplicate

> **V1 note:** This phase is optional for now. The initial implementation can return validated outputs directly without automated retries, similarity filtering, or deduplication. This phase can be added once the core generation pipeline is working reliably.

## Objective

When enabled, this phase improves output quality by removing or regenerating outputs that:
- fail critical blueprint requirements,
- are visually broken,
- are too similar to each other,
- are too close to the original,
- are too far from the original format.

## Retry logic

Example:

```text
Variation v4 generated
↓
Validation fails:
"face not obscured"
↓
Create corrective retry
↓
Regenerate v4
↓
Validate again
```

## Example corrective retry instruction

> Example only.

```text
Retry this variation.

The previous output failed because the subject's face was visible.

Preserve the previous variation plan, but ensure the face is clearly obscured by the requested graphic.

Do not substantially change the car interior, pose, lighting, or subject styling.
```

## Deduplication

Compare:
- each output to the original,
- each output to all other generated outputs.

The goal is:

```text
same creative family
≠
same image
```

## Embedding-based similarity

One possible implementation:

```text
original image
↓
visual embedding A

variation image
↓
visual embedding B

cosine similarity(A, B)
```

This can help identify:
- near duplicates,
- outputs that drift too far.

## Example similarity policy

> Illustrative only. These numbers should be validated empirically.

```text
> 0.93 similarity:
possibly too close

0.65–0.90:
potentially useful variation band

< 0.45:
possibly too far from original concept
```

Do not hard-code these values before testing with real creatives.

## Pairwise deduplication

Also compare:

```text
v1 ↔ v2
v1 ↔ v3
v2 ↔ v3
...
```

If several outputs look nearly identical, keep the strongest and regenerate the others.

---

# 11. Phase 9 — Return the Final Set

## Objective

Return a polished subset rather than raw generations.

Example:

```text
Requested variations: 6
Raw generations: 10
Validation passed: 8
Deduplication retained: 7
Final ranked outputs returned: 6
```

## Possible ranking signals

For V1, ranking might incorporate:
- blueprint compliance,
- variation-plan compliance,
- visual quality,
- diversity from original,
- diversity from other results,
- subject realism,
- composition quality.

You do not necessarily need a sophisticated ML ranker at launch.

A simple weighted scoring system could be enough.

## Example ranking record

> Example only.

```json
{
  "variation_id": "v7",
  "scores": {
    "blueprint_match": 0.93,
    "plan_compliance": 0.91,
    "visual_quality": 0.88,
    "novelty_vs_original": 0.79,
    "diversity_vs_batch": 0.86
  },
  "final_score": 0.89
}
```

---

# 12. Full Backend Flow

```text
                       USER
                        │
                        ▼
                 Upload reference
                        │
                        ▼
          ┌───────────────────────────┐
          │ 1. INGEST + NORMALIZE     │
          └─────────────┬─────────────┘
                        │
                        ▼
          ┌───────────────────────────┐
          │ 2. ANALYZE CREATIVE       │
          │    STRUCTURE              │
          └─────────────┬─────────────┘
                        │
                        ▼
              Raw creative analysis
                        │
                        ▼
          ┌───────────────────────────┐
          │ 3. BUILD CANONICAL        │
          │    CREATIVE BLUEPRINT     │
          └─────────────┬─────────────┘
                        │
                        ▼
                Creative blueprint
                        │
                        ▼
          ┌───────────────────────────┐
          │ 4. GENERATE N VARIATION   │
          │    PLANS                  │
          └─────────────┬─────────────┘
                        │
            ┌───────────┼───────────┐
            ▼           ▼           ▼
           v1          v2          vN
            │           │           │
            ▼           ▼           ▼
          ┌───────────────────────────┐
          │ 5. IMAGE GENERATION       │
          └─────────────┬─────────────┘
                        │
                        ▼
               Generated visuals
                        │
                        ▼
          ┌───────────────────────────┐
          │ 6. TEXT / OVERLAY RENDER  │
          └─────────────┬─────────────┘
                        │
                        ▼
                 Complete slides
                        │
                        ▼
          ┌───────────────────────────┐
          │ 7. VALIDATE AGAINST       │
          │    BLUEPRINT              │
          └─────────────┬─────────────┘
                        │
                ┌───────┴────────┐
                ▼                ▼
              PASS             FAIL
                │                │
                │                ▼
                │            regenerate
                │                │
                └────────┬───────┘
                         ▼
          ┌───────────────────────────┐
          │ 8. FILTER + DEDUP + RETRY │
          └─────────────┬─────────────┘
                        │
                        ▼
          ┌───────────────────────────┐
          │ 9. RETURN FINAL SET       │
          └───────────────────────────┘
```

---

# 13. Why the System Uses Both a Blueprint and the Original Image

It may seem redundant to send both:
- the original image,
- a JSON blueprint describing the image.

They serve different purposes.

## Original image

Provides:
- visual style,
- spatial composition,
- lighting,
- realism,
- texture,
- overall aesthetic context.

## Blueprint

Provides:
- explicit creative intent,
- invariants,
- allowed variation dimensions,
- constraints,
- a stable interface between models.

The image is **rich but ambiguous**.

The blueprint is **simplified but controllable**.

Together they are much stronger.

This remains true even when the underlying model is natively multimodal. Native multimodality reduces the need for JustPost to build its own vision-feature pipeline, but it does **not** remove the need for a product-level blueprint. The blueprint exists to provide explicit control, persistence, inspectability, downstream planning, and validation.

---

# 14. Why JustPost Should Not Replicate the Model's Internal Multimodal Representation

A multimodal model already converts images into internal learned representations that it can reason over jointly with text.

Those internal representations may involve:
- visual embeddings,
- visual tokens,
- learned numerical features,
- modality-specific processing.

JustPost does **not** need to recreate or expose those internal vectors.

The product-level representation should live at a higher abstraction level.

Bad target:

```text
"store every feature the model internally sees"
```

Better target:

```text
"store what matters for creating a good variation"
```

The canonical blueprint exists for product control, not because the vision model cannot understand the image.

---

# 15. Separation of Responsibilities

A useful mental model for the V1 backend:

## Multimodal analyzer
Answers:
> "What is happening in this creative?"

## Blueprint builder
Answers:
> "What parts of this matter for maintaining the winning format?"

## Variation planner
Answers:
> "How should each new creative intentionally differ?"

## Image generator
Answers:
> "What should the new visual look like?"

## Renderer
Answers:
> "How should exact copy and overlays be composed?"

## Validator
Answers:
> "Did the generation actually follow the plan?"

---

# 16. Example End-to-End Walkthrough

Suppose the user uploads the earlier car image.

## Input

```text
Original:
- modest female creator
- olive hijab
- inside car
- pink heart covering face
- green drink
- instructional copy
```

## Analysis result

```text
Creative type:
UGC hook slide

Hook:
how-to + recurring daily value

Aesthetic:
casual, mobile-native, aspirational

Visual device:
graphic obscuring face
```

## Blueprint result

```text
Must preserve:
- modest Muslim UGC creator
- car environment
- face obscured
- casual selfie aesthetic
- large hook copy

Can vary:
- hijab color
- drink
- heart/sticker design
- car interior
- pose
- hook wording
```

## Variation plan A

```text
cream hijab
iced coffee
beige heart
brown interior
slight side angle
POV-style hook
```

## Variation plan B

```text
black hijab
matcha
white flower
dark interior
slightly lowered gaze
how-to hook
```

## Generation

Create separate images for A and B.

## Render

Add hook copy after the image is generated.

## Validate

A:
- passes

B:
- face accidentally visible
- retry

## Retry B

Corrective prompt requests:
- face must remain obscured

## Final output

Return A, corrected B, and the other top-ranked valid variations.

---

# 17. Suggested V1 Scope

To keep V1 manageable, avoid adding too much logic initially.

## Required
- image upload,
- vision analysis,
- blueprint generation,
- variation planning,
- image generation,
- deterministic text rendering,
- blueprint validation,
- final result set.

## Optional for V1 / add later
- retrying failed generations,
- filtering weak outputs,
- deduplication,
- similarity scoring,
- manual region selection,
- locked image regions,
- masks/inpainting,
- user-selectable variation strength,
- per-element controls,
- automated segmentation,
- historical performance learning,
- advanced similarity ranking,
- multi-slide carousel analysis.

---

# 18. Possible Service Boundaries

You may eventually structure the backend into services like:

```text
Asset Service
    ↓
Multimodal Creative Analysis Service
    ↓
Blueprint Service
    ↓
Variation Planning Service
    ↓
Generation Orchestrator
    ↓
Rendering Service
    ↓
Validation Service
    ↓
Ranking Service
```

For an MVP, these do not need to be separate deployed microservices.

They can be modules within one backend application.

The important part is conceptual separation.

---

# 19. Example Internal Job Object

> Example only. This illustrates state management, not a required schema.

```json
{
  "job_id": "job_01JPOSTABC",
  "source_asset_id": "img_01JPOST123",
  "status": "generating",
  "requested_variations": 6,
  "analysis_id": "analysis_01",
  "blueprint_id": "blueprint_01",
  "variation_plans": [
    "v1",
    "v2",
    "v3",
    "v4",
    "v5",
    "v6"
  ],
  "generation_state": {
    "completed": 4,
    "pending": 2,
    "failed": 1,
    "retrying": 1
  }
}
```

---

# 20. The Most Important Design Principle

The core V1 principle should be:

> **Understand → plan → generate → verify.**

Not:

> **Upload → randomly generate.**

In shorthand:

```text
SOURCE
↓
UNDERSTAND
↓
ABSTRACT
↓
PLAN
↓
CREATE
↓
VERIFY
↓
RETURN
```

The benefit of this architecture is that each stage produces an artifact that can be:
- inspected,
- logged,
- evaluated,
- improved independently.

If outputs are bad, you can identify where the failure occurred:

```text
Was the analysis wrong?
Was the blueprint wrong?
Was the variation plan weak?
Did generation ignore the plan?
Did validation fail to catch it?
```

That is much more useful than having one opaque model call responsible for the entire product experience.

---

# 21. Summary

The JustPost V1 backend should follow this canonical flow:

```text
1. Ingest + normalize
2. Analyze creative structure
3. Build canonical creative blueprint
4. Generate N variation plans
5. Create images from each plan
6. Render text / overlays separately
7. Validate against blueprint
8. (Optional) Retry / filter / deduplicate
9. Return final set
```

The original image remains valuable throughout the pipeline because it contains rich visual information.

The blueprint is valuable because it turns that rich but ambiguous image into a controllable product-level representation.

The variation planner is valuable because it creates deliberate diversity before expensive image generation.

The validator is valuable because generation should not automatically equal acceptance.

Together, these phases make JustPost less like a generic image-generation wrapper and more like a structured **creative variation engine**.
