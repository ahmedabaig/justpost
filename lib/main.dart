import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'firebase_options.dart';
import 'shell/app_shell.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The shell draws its own background behind the status and navigation bars.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await _activateAppCheck();
  runApp(const JustPostApp());
}

/// Debug builds use a debug token that must be registered in the Firebase
/// console (App Check → Manage debug tokens). Pass a fixed one with
/// `--dart-define=APP_CHECK_DEBUG_TOKEN=...`, or leave it empty and copy the
/// generated token from the run log.
Future<void> _activateAppCheck() {
  const debugToken = String.fromEnvironment('APP_CHECK_DEBUG_TOKEN');
  final token = debugToken.isEmpty ? null : debugToken;
  return FirebaseAppCheck.instance.activate(
    providerApple: kDebugMode
        ? AppleDebugProvider(debugToken: token)
        : const AppleAppAttestProvider(),
    providerAndroid: kDebugMode
        ? AndroidDebugProvider(debugToken: token)
        : const AndroidPlayIntegrityProvider(),
  );
}

class JustPostApp extends StatelessWidget {
  const JustPostApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JustPost',
      debugShowCheckedModeBanner: false,
      theme: buildJustPostTheme(),
      home: const AppShell(),
    );
  }
}
