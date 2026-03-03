import 'dart:math' show sqrt;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 그레이스케일 정규화 상호상관 기반 템플릿 매칭
class TemplateMatcher {
  /// 화면 이미지에서 템플릿 찾기. 스케일 0.7~1.3, step 2 픽셀.
  /// 반환: (결과, 실패 시 최고 일치도). 결과가 null이면 bestConfidenceOnFail에 최고 점수.
  static (((int x, int y) rel, double confidence, double scale)? result, double? bestConfidenceOnFail) find({
    required img.Image screen,
    required img.Image template,
    double threshold = 0.7,
    List<double> scales = const [0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3],
    int step = 2,
  }) {
    final sw = screen.width;
    final sh = screen.height;
    final tw0 = template.width;
    final th0 = template.height;

    double bestConf = 0;
    int bestX = 0, bestY = 0;
    double bestScale = 1.0;

    for (final scale in scales) {
      if (scale <= 0) continue;
      final tw = (tw0 * scale).round();
      final th = (th0 * scale).round();
      if (tw < 8 || th < 8 || tw > sw || th > sh) continue;

      final resized = img.copyResize(template, width: tw, height: th);
      final screenGray = img.grayscale(screen);
      final templGray = img.grayscale(resized);

      final sBytes = _toGrayBytes(screenGray);
      final tBytes = _toGrayBytes(templGray);

      for (int y = 0; y <= sh - th; y += step) {
        for (int x = 0; x <= sw - tw; x += step) {
          final c = _nccAt(sBytes, sw, sh, tBytes, tw, th, x, y);
          if (c > bestConf) {
            bestConf = c;
            bestX = x;
            bestY = y;
            bestScale = scale;
          }
        }
      }
    }

    if (bestConf < threshold) return (null, bestConf);
    return (((bestX, bestY), bestConf, bestScale), null);
  }

  static Float32List _toGrayBytes(img.Image im) {
    final w = im.width;
    final h = im.height;
    final out = Float32List(w * h);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final p = im.getPixel(x, y);
        out[y * w + x] = (p.r + p.g + p.b) / 3;
      }
    }
    return out;
  }

  /// 정규화 상호상관 (NCC) - 0~1, 1이 완전 일치
  static double _nccAt(
    Float32List screen,
    int sw,
    int sh,
    Float32List templ,
    int tw,
    int th,
    int ox,
    int oy,
  ) {
    int n = 0;
    double sumS = 0, sumT = 0;
    for (int dy = 0; dy < th; dy++) {
      for (int dx = 0; dx < tw; dx++) {
        final sy = oy + dy;
        final sx = ox + dx;
        if (sx >= sw || sy >= sh) continue;
        final s = screen[sy * sw + sx];
        final t = templ[dy * tw + dx];
        sumS += s;
        sumT += t;
        n++;
      }
    }
    if (n == 0) return 0;
    final meanS = sumS / n;
    final meanT = sumT / n;

    double numSum = 0, denS = 0, denT = 0;
    for (int dy = 0; dy < th; dy++) {
      for (int dx = 0; dx < tw; dx++) {
        final sy = oy + dy;
        final sx = ox + dx;
        if (sx >= sw || sy >= sh) continue;
        final ds = (screen[sy * sw + sx] - meanS);
        final dt = (templ[dy * tw + dx] - meanT);
        numSum += ds * dt;
        denS += ds * ds;
        denT += dt * dt;
      }
    }
    final den = denS * denT;
    if (den <= 0) return 0;
    var r = numSum / sqrt(den);
    r = (r + 1) / 2;
    return r.clamp(0.0, 1.0);
  }
}
