import 'package:flutter/foundation.dart';

/// Shows unchecked AI output for inspection. On in debug builds, and in
/// release builds made with `--dart-define=JUSTPOST_INSPECT=true` (TestFlight).
/// App Store builds must leave it off.
const bool showAiInspection =
    kDebugMode || bool.fromEnvironment('JUSTPOST_INSPECT');
