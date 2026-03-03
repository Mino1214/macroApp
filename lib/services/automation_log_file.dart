import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

/// 자동화 로그를 파일로 저장. Download/nexus_log 폴더 사용 (adb pull 용이)
class AutomationLogFile {
  static File? _file;
  static String? _path;

  /// log 폴더 경로. Android: Download/nexus_log (공개 폴더)
  static Future<String> getLogDirectory() async {
    if (Platform.isAndroid) {
      try {
        final dir = await const MethodChannel('com.example.nexus_flutter/app')
            .invokeMethod<String>('getLogDirectory');
        if (dir != null && dir.isNotEmpty) return dir;
      } catch (_) {}
    }
    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null && ext.path.isNotEmpty) {
        return p.join(ext.path, 'log');
      }
    } catch (_) {}
    final base = (await getApplicationDocumentsDirectory()).path;
    return p.join(base, 'log');
  }

  static Future<String> get logPath async {
    if (_path != null) return _path!;
    final dir = await getLogDirectory();
    Directory(dir).createSync(recursive: true);
    _path = p.join(dir, 'nexus_automation_log.txt');
    return _path!;
  }

  static Future<void> append(String line) async {
    try {
      final path = await logPath;
      _file ??= File(path);
      final timestamp = DateTime.now().toIso8601String().substring(11, 19);
      await _file!.writeAsString('[$timestamp] $line\n', mode: FileMode.append);
    } catch (_) {}
  }

  static Future<void> clear() async {
    try {
      final path = await logPath;
      final f = File(path);
      if (f.existsSync()) await f.writeAsString('');
      _file = f;
    } catch (_) {}
  }
}
