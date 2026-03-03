import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'theme/app_theme.dart';
import 'screens/login_screen.dart';
import 'screens/main_screen.dart';
import 'services/automation_log_file.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid) {
    final dir = await AutomationLogFile.getLogDirectory();
    Directory(dir).createSync(recursive: true);
  }
  runApp(const NexusApp());
}

class NexusApp extends StatelessWidget {
  const NexusApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nexus',
      theme: AppTheme.darkTheme,
      initialRoute: '/login',
      routes: {
        '/login': (_) => const LoginScreen(),
        '/main': (_) => const MainScreen(),
      },
    );
  }
}
