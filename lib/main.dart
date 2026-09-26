import 'package:firebase_core/firebase_core.dart';
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
  runApp(const JustPostApp());
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
