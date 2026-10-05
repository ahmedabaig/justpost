# JustPost

JustPost is an early-stage slideshow variation tool for TikTok affiliates. It
uses an existing high-performing slide as the creative reference and generates
new variations that keep what made the original work.

The repository currently contains:

- A Flutter application for iOS and Android.
- A Firebase backend (project `justpost-mobile`) with one Python Cloud
  Function, `ingest_asset`, that stores and normalizes a reference slide.

No AI calls exist yet. The current backend phase is described in
[`docs/phase-1-ingest-plan.md`](docs/phase-1-ingest-plan.md).

## Run the Flutter app

```bash
flutter pub get
flutter run
```

To ship a TestFlight build, increase the build number in `pubspec.yaml`, run
`flutter build ipa`, and upload `build/ios/ipa/*.ipa` with Transporter.

The app presents a shell with three tabs — Create, Library, and You — behind a
floating glass navigation pill. Create picks a slideshow from the photo
library; "Use as reference" uploads the slide on screen, waits for
`ingest_asset`, and opens a screen comparing the original with the backend's
analysis copy.

UI code is organized as `lib/theme` (design tokens and `ThemeData`),
`lib/shell` (the layout shell and navigation), `lib/widgets` (shared
primitives), and `lib/features/<feature>` (screens and their services).

### App Check debug token

The backend only accepts calls with a valid App Check token. Release builds
(TestFlight) use App Attest. Debug builds, including the simulator, use a debug
token that has to be registered once:

1. Run the app in debug mode and search the Xcode or `flutter run` log for
   `App Check debug token`.
2. In the Firebase console, open App Check → Apps → the iOS app → Manage debug
   tokens, and add that token.

To keep the same token across reinstalls, run with
`--dart-define=APP_CHECK_DEBUG_TOKEN=<token>`. Treat the token like a password:
don't commit or share it.

## Backend

`functions/` holds the Python 3.12 Cloud Functions code:
`justpost/ingest.py` (pure image normalization) and `main.py` (the callable
function and its Storage and Firestore I/O). Security rules are in
`firestore.rules` and `storage.rules`.

```bash
cd functions
python3.12 -m venv venv
./venv/bin/pip install -r requirements.txt pytest
./venv/bin/python -m pytest -q
```

Deploy from the repository root:

```bash
firebase deploy --only functions,firestore,storage --project justpost-mobile
```

## Conventions

- Layout coordinates use fractional `0–1` values so preview and export share
  the same representation.
- API keys and generated secret configuration must never be committed. Future
  model keys go in Secret Manager via `firebase functions:secrets:set`, never
  in `functions/.env`.
