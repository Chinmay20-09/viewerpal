import 'package:flutter/material.dart';

import '../core/models/document_file.dart';
import '../features/home/home_screen.dart';
import '../features/viewer/viewer_screen.dart';

/// Root MaterialApp for the Document Environment.
class DocumentEnvironmentApp extends StatelessWidget {
  const DocumentEnvironmentApp({super.key});

  @override
  Widget build(BuildContext named) {
    return MaterialApp(
      title: 'Document Environment',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      initialRoute: HomeScreen.routeName,
      routes: {
        HomeScreen.routeName: (context) => const HomeScreen(),
      },
      onGenerateRoute: (settings) {
        if (settings.name == ViewerScreen.routeName) {
          final args = settings.arguments;
          if (args is DocumentFile) {
            return MaterialPageRoute<void>(
              builder: (_) => ViewerScreen(document: args),
            );
          }
        }
        return null;
      },
    );
  }
}
