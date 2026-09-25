# JustPost

JustPost is an early-stage slideshow variation tool for TikTok affiliates. It
uses an existing slideshow as the creative baseline, analyzes the role and
visual structure of each slide, and generates controlled image variations
without intentionally changing protected content.

The repository currently contains:

- A minimal Flutter application scaffold for future iOS and Android clients.
- Firebase initialization and platform configuration.
- A Python validation pipeline under `phase1/`.

## Current image pipeline

For each slideshow, the Phase 1 pipeline:

1. Uses Gemini to analyze the slideshow format and extract a structured graph of each slide's visual elements.
2. Derives effective edit permissions from application policy.
3. Builds a constrained variation prompt from the slideshow analysis and slide graph.
4. Uses OpenAI image generation with the original image as the baseline.
5. Restores and verifies protected regions.
6. Falls back to the original image when verification fails or is uncertain.

Generated analyses, graphs, prompts, edited images, verified outputs, and the batch summary are written to `phase1/outputs/`.

## Run the Phase 1 pipeline

Create `phase1/.env` from the example and provide:

```text
GEMINI_API_KEY=...
OPENAI_API_KEY=...
```

Then install the Python dependencies and run a slideshow:

```bash
cd phase1
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python run_batch.py ex1
```

Omit `ex1` to process every slideshow under `phase1/slideshows/`.

`OPENAI_IMAGE_MODEL` is optional and can be set in `phase1/.env` to override
the pipeline's default image model.

## Run the Flutter app

```bash
flutter pub get
flutter run
```

The Flutter app currently initializes Firebase and presents an empty
application shell. Product screens and pipeline integration have not yet been
implemented.

## Important safety constraints

- Model-generated permissions and edit instructions are untrusted.
- Every edit must pass the application permission filter.
- Protected regions must be checked against the original image.
- Failed or uncertain verification must return the original image.
- Layout coordinates use fractional `0–1` values so preview and export share
  the same representation.
- API keys and generated secret configuration must never be committed.
