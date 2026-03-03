import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// mnemonic_attempt_count.txt 에 니모닉문구 시도 횟수 저장·읽기 (모바일용 path_provider)
class WalletCountFile {
  static String? _basePath;

  static Future<String> get _filePath async {
    _basePath ??= (await getApplicationDocumentsDirectory()).path;
    return p.join(_basePath!, 'mnemonic_attempt_count.txt');
  }

  static Future<int> read() async {
    try {
      final path = await _filePath;
      final f = File(path);
      if (!f.existsSync()) return 0;
      final s = f.readAsStringSync().trim();
      final n = int.tryParse(s);
      return (n != null && n >= 0) ? n : 0;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> increment() async {
    try {
      final n = await read() + 1;
      final path = await _filePath;
      Directory(p.dirname(path)).createSync(recursive: true);
      File(path).writeAsStringSync('$n');
    } catch (_) {}
  }
}
