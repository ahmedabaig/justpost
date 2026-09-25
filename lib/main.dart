import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const JustPostApp());
}

class JustPostApp extends StatelessWidget {
  const JustPostApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'JustPost',
      home: Scaffold(body: SizedBox.expand()),
    );
  }
}
