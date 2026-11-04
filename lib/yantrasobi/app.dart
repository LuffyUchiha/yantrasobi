import 'package:flutter/material.dart';

import 'runtime/services.dart';
import 'ui/library_screen.dart';

/// Root widget of the Yantrasobi console.
class YantrasobiApp extends StatelessWidget {
  const YantrasobiApp({super.key, required this.services});

  final AsobiServices services;

  static ThemeData theme() {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFFFFB020),
      brightness: Brightness.dark,
      surface: const Color(0xFF12131F),
    );
    return ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFF0B0C15),
      useMaterial3: true,
      appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF0B0C15), centerTitle: false),
      cardTheme: const CardThemeData(color: Color(0xFF181A2B)),
    );
  }

  @override
  Widget build(BuildContext context) => AsobiScope(
    services: services,
    child: MaterialApp(
      title: 'Yantrasobi',
      debugShowCheckedModeBanner: false,
      theme: theme(),
      home: const LibraryScreen(),
    ),
  );
}
