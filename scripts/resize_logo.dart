// 로고 0.7배 축소 → logo.png 생성
// dart run scripts/resize_logo.dart
import 'dart:io';

import 'package:image/image.dart' as img;

void main() async {
  final src = File('assets/data/logo.png');
  if (!src.existsSync()) {
    print('assets/data/logo.png 없음');
    exit(1);
  }

  final bytes = await src.readAsBytes();
  final image = img.decodeImage(bytes);
  if (image == null) {
    print('이미지 디코딩 실패');
    exit(1);
  }
  final w = (image.width * 0.7).round();
  final h = (image.height * 0.7).round();
  final resized = img.copyResize(image, width: w, height: h);
  final out = File('assets/data/logo.png');
  out.parent.createSync(recursive: true);
  await out.writeAsBytes(img.encodePng(resized));
  print('logo.png 생성됨 (${w}x$h)');
}
