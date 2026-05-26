import 'package:flutter/material.dart';
import 'connection_screen.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Conexão',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
      home: const ConnectionScreen(),
    );
  }
}
