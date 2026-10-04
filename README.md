# JustPost

JustPost is an early-stage slideshow variation tool for TikTok affiliates. It
uses an existing slideshow as the creative baseline, analyzes the role and
visual structure of each slide, and generates controlled image variations
without intentionally changing protected content.

The repository currently contains:

- A minimal Flutter application scaffold for future iOS and Android clients.
- Firebase initialization and platform configuration.
- The Python variation pipeline (`functions/justpost_phase1/`), deployed as the
  `create_variation` Cloud Function.
- A local batch runner under `phase1/` for testing the pipeline on your own
  slideshows.

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
pip install -r ../functions/requirements.txt
python run_batch.py ex1
```

Omit `ex1` to process every slideshow under `phase1/slideshows/`.

`OPENAI_IMAGE_MODEL` is optional and can be set in `phase1/.env` to override
the pipeline's default image model.

## Cloud Function

The app uploads slides to Storage under `jobs/{uid}/{jobId}/input/`, then calls
`create_variation`. The function runs the pipeline, uploads each shipped slide
to `jobs/{uid}/{jobId}/output/`, and reports progress in the Firestore document
`jobs/{jobId}`, which the app watches.

One-time setup for the `justpost-baig` project:

1. Upgrade to the Blaze plan and enable Storage and Anonymous sign-in.
2. Store the API keys in Secret Manager (paste each key when prompted):

   ```bash
   firebase functions:secrets:set OPENAI_API_KEY
   firebase functions:secrets:set GEMINI_API_KEY
   ```

3. Register the iOS app with App Check using App Attest, and add the
   simulator's debug token under App Check > Manage debug tokens.

Never put API keys in `functions/.env`; Firebase deploys that file as plain
environment variables.

Run the backend tests and deploy:

```bash
cd functions
python3.12 -m venv venv
./venv/bin/pip install -r requirements.txt pytest
./venv/bin/python -m pytest -q
cd ..
firebase deploy --only functions,firestore,storage
```

## Run the Flutter app

```bash
flutter pub get
flutter run --dart-define=APP_CHECK_DEBUG_TOKEN=<token>
```

`APP_CHECK_DEBUG_TOKEN` is optional. Without it, the first debug run prints a
token in the logs that you register in the Firebase console. Release builds use
App Attest instead.

To ship a TestFlight build, increase the build number in `pubspec.yaml`, run
`flutter build ipa`, and upload `build/ios/ipa/*.ipa` with Transporter.

The Flutter app initializes Firebase and presents a dark-themed shell with
three tabs — Create, Library, and You — behind a floating glass navigation
pill. Create can pick a slideshow from the photo library, review it slide by
slide, and send it to the Cloud Function with Generate variation, which shows
each result beside its original.

UI code is organized as `lib/theme` (design tokens and `ThemeData`),
`lib/shell` (the layout shell and navigation), `lib/widgets` (shared
primitives), and `lib/features/<feature>` (screens).

## Important safety constraints

- Model-generated permissions and edit instructions are untrusted.
- Every edit must pass the application permission filter.
- Protected regions must be checked against the original image.
- Failed or uncertain verification must return the original image.
- Layout coordinates use fractional `0–1` values so preview and export share
  the same representation.
- API keys and generated secret configuration must never be committed.
