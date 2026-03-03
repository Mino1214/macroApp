import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:media_projection_screenshot/media_projection_screenshot.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'automation_log_file.dart';

/// Android 이미지 캡처 + 템플릿 매칭 + 터치 (API 24+ dispatchGesture)
/// 템플릿 폴더: data/trustwallet/ (first, second, third, fourth, phrase1~4, chain, wordinput, wordpaste, wordnext, fail, success, successPage, wallet, delete, delete2, 0~9)
class AndroidImageMatcher {
  static MediaProjectionScreenshot? _screenshot;
  static MediaProjectionScreenshot get _screenshotOrCreate => _screenshot ??= MediaProjectionScreenshot();
  static const _channel = MethodChannel('com.example.nexus_flutter/app');
  static const double stateMatchThreshold = 0.3;

  /// 디버그용: 설정하면 각 단계 로그 출력
  static void Function(String text)? debugLog;
  static void _log(String s) {
    try {
      debugLog?.call(s);
    } catch (_) {}
  }

  /// 템플릿 서브폴더: null/'trustwallet' = Trust Wallet, 'app' = SafePal (first.png, errorword.png)
  static String? templateSubdir;

  // 이미지 매칭 비활성화
  // /// SafePal: 번들 템플릿을 documents로 복사 (릴리즈 APK에서 rootBundle 이슈 대비)
  // static Future<void> ensureAppTemplatesInDocuments() async {
  //   const templates = ['first', 'errorword'];
  //   final subdir = templateSubdir ?? 'trustwallet';
  //   if (subdir != 'app') return;
  //   try {
  //     final dirPath = await picsDir;
  //     final dir = Directory(dirPath);
  //     if (!dir.existsSync()) dir.createSync(recursive: true);
  //     for (final name in templates) {
  //       final f = '$name.png';
  //       try {
  //         final bytes = await rootBundle.load('assets/data/app/$f');
  //         final file = File(p.join(dirPath, f));
  //         await file.writeAsBytes(bytes.buffer.asUint8List());
  //       } catch (_) {}
  //     }
  //   } catch (_) {}
  // }
  static Future<void> ensureAppTemplatesInDocuments() async {}

  /// 템플릿 이미지 폴더 경로 (data/trustwallet 또는 data/app)
  static Future<String> get picsDir async {
    final base = (await getApplicationDocumentsDirectory()).path;
    final subdir = templateSubdir ?? 'trustwallet';
    return p.join(base, 'data', subdir);
  }

  static Future<void> requestScreenPermission() async {
    _screenshotOrCreate.requestPermission();
  }

  static Future<bool> hasTouchPermission() async {
    try {
      final ok = await _channel.invokeMethod<bool>('hasTouchPermission');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> requestTouchPermission() async {
    await _channel.invokeMethod('requestTouchPermission');
  }

  /// 자동화 중 절전/화면꺼짐으로 앱이 멈추지 않도록 WakeLock 획득
  static Future<void> acquireWakeLock() async {
    try {
      await _channel.invokeMethod('acquireWakeLock');
    } catch (_) {}
  }

  /// WakeLock 해제 (자동화 종료 시)
  static Future<void> releaseWakeLock() async {
    try {
      await _channel.invokeMethod('releaseWakeLock');
    } catch (_) {}
  }

  /// 현재 포그라운드 화면(Trust Wallet 등)의 접근성 노드에 있는 text/contentDescription 목록 (중복 제거, 정렬)
  static Future<List<String>> getAccessibilityNodeTexts() async {
    try {
      final list = await _channel.invokeMethod<List<Object>>('getAccessibilityNodeTexts');
      if (list == null) return [];
      return list.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
    } catch (_) {
      return [];
    }
  }

  /// 백 키 전송 (키보드 숨기기)
  static Future<bool> pressBack() async {
    try {
      final ok = await _channel.invokeMethod<bool>('pressBack');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 포커스된 입력 필드 전체 선택 (Ctrl+A)
  static Future<bool> selectAll() async {
    try {
      final ok = await _channel.invokeMethod<bool>('selectAll');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// UIAutomator 2.0 스타일: resourceId/text/contentDesc/className으로 노드 찾아 클릭.
  /// tapAtRight: true면 노드 영역 오른쪽 끝으로 터치 (지갑 row 등)
  /// 반환: (성공여부, 매칭된 노드 설명, 노드 없을 때 화면 노드 요약)
  static Future<(bool, String?, String?)> clickBySelector({
    String? resourceId,
    String? text,
    String? contentDesc,
    String? className,
    bool tapAtRight = false,
  }) async {
    if (resourceId == null && text == null && contentDesc == null && className == null) {
      return (false, null, null);
    }
    try {
      final args = <String, Object?>{};
      if (resourceId != null && resourceId.isNotEmpty) args['resourceId'] = resourceId;
      if (text != null && text.isNotEmpty) args['text'] = text;
      if (contentDesc != null && contentDesc.isNotEmpty) args['contentDesc'] = contentDesc;
      if (className != null && className.isNotEmpty) args['className'] = className;
      if (tapAtRight) args['tapAtRight'] = true;
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>('clickBySelector', args);
      final ok = res?['ok'] == true;
      final matched = res?['matched']?.toString();
      final screenNodes = res?['screenNodes']?.toString();
      return (ok, matched, screenNodes);
    } catch (e) {
      _log('[선택자] 오류: $e');
      return (false, null, null);
    }
  }

  /// 수집 모드 시작 (Trust Wallet으로 전환 후 5초마다 노드 자동 수집)
  static Future<bool> startNodeCollector() async {
    try {
      final ok = await _channel.invokeMethod<bool>('startNodeCollector');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 수집 모드 중지
  static Future<bool> stopNodeCollector() async {
    try {
      final ok = await _channel.invokeMethod<bool>('stopNodeCollector');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 현재 활성 창의 패키지명 (Trust Wallet 전환 확인용)
  static Future<String?> getActiveWindowPackage() async {
    try {
      final pkg = await _channel.invokeMethod<String>('getActiveWindowPackage');
      return pkg;
    } catch (_) {
      return null;
    }
  }

  /// 수집 모드 실행 중인지
  static Future<bool> isNodeCollectorRunning() async {
    try {
      final ok = await _channel.invokeMethod<bool>('isNodeCollectorRunning');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 수집 모드 누적 수집 횟수
  static Future<int> getNodeCollectorCount() async {
    try {
      final n = await _channel.invokeMethod<int>('getNodeCollectorCount');
      return n ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// paste/next 클릭과 동일한 방식으로 화면 판정. Kotlin findNodeBySelector와 같은 트리 순회 + contentDesc contains.
  /// "fail" | "success" | "none"
  static Future<String> checkScreenKeywords({
    required List<String> failKeywords,
    required List<String> successKeywords,
  }) async {
    try {
      final r = await _channel.invokeMethod<String>('checkScreenKeywords', {
        'failKeywords': failKeywords,
        'successKeywords': successKeywords,
      });
      return r ?? 'none';
    } catch (_) {
      return 'none';
    }
  }

  /// UIAutomator 선택자 작성용: 현재 화면 노드 목록 (id | text | desc)
  static Future<List<String>> getNodeDetailsForSelectors() async {
    try {
      final list = await _channel.invokeMethod<List<Object>>('getNodeDetailsForSelectors');
      if (list == null) return [];
      return list.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
    } catch (_) {
      return [];
    }
  }

  /// MediaProjection 없이 접근성 노드로 텍스트/설명 일치하면 클릭
  static Future<bool> clickByAccessibilityText(String text) async {
    if (text.isEmpty) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('clickByAccessibility', {'text': text});
      _log('[접근성노드] "$text" 클릭결과: $ok');
      return ok ?? false;
    } catch (e) {
      _log('[접근성노드] "$text" 오류: $e');
      return false;
    }
  }

  static Future<Uint8List?> _captureScreen(int x, int y, int w, int h) async {
    return null; // 화면캡처 비활성화 — MediaProjection 팝업 방지
    // try {
    //   final result = await _screenshot
    //       .takeCapture(x: x, y: y, width: w, height: h)
    //       .timeout(const Duration(seconds: 15));
    //   final bytes = result?.bytes;
    //   ...
    // } catch (e, st) { ... }
  }

  /// 화면 변경 감지용: 이미지를 32x32로 줄여 해시 계산 (image 4.x 호환)
  static int _hashImage(img.Image image) {
    final small = img.copyResize(image, width: 32, height: 32);
    int h = 0;
    for (var y = 0; y < small.height; y++) {
      for (var x = 0; x < small.width; x++) {
        final p = small.getPixel(x, y);
        final v = (p.r.toInt() + p.g.toInt() + p.b.toInt()) & 0xFF;
        h = ((h * 31) + v) & 0x7FFFFFFF;
      }
    }
    return h;
  }

  /// 현재 화면 캡처 후 해시 반환 (화면 변경 감지용)
  static Future<int?> getScreenHash() async {
    if (!Platform.isAndroid) return null;
    final (w, h) = await _getScreenSize();
    final bytes = await _captureScreen(0, 0, w, h);
    if (bytes == null || bytes.isEmpty) return null;
    final screenImg = img.decodeImage(bytes);
    if (screenImg == null) return null;
    return _hashImage(screenImg);
  }

  /// 화면이 이전 해시와 달라질 때까지 대기 (최대 timeout). 변경 시 true, 타임아웃 시 false.
  static Future<bool> waitForScreenChange(
    int? previousHash, {
    Duration firstWait = const Duration(milliseconds: 600),
    Duration pollInterval = const Duration(milliseconds: 500),
    Duration timeout = const Duration(seconds: 6),
  }) async {
    if (previousHash == null) return true;
    await Future.delayed(firstWait);
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < timeout) {
      final current = await getScreenHash();
      if (current != null && current != previousHash) return true;
      await Future.delayed(pollInterval);
    }
    return false;
  }

  /// 캡처/터치 좌표 일치를 위해 Android에서는 네이티브 디스플레이 크기 사용
  static Future<(int w, int h)> _getScreenSize() async {
    if (Platform.isAndroid) {
      try {
        final map = await _channel.invokeMethod<Map<Object?, Object?>>('getDisplaySize');
        if (map != null) {
          final w = map['width'] as num?;
          final h = map['height'] as num?;
          if (w != null && h != null && w.toInt() > 0 && h.toInt() > 0) {
            return (w.toInt(), h.toInt());
          }
        }
      } catch (_) {}
    }
    final size = ui.PlatformDispatcher.instance.views.firstOrNull?.physicalSize;
    if (size != null && size.width > 0 && size.height > 0) {
      return (size.width.toInt(), size.height.toInt());
    }
    return (1080, 2400);
  }

  static Future<String> _templatePath(String name) async {
    final dir = await picsDir;
    final f = name.endsWith('.png') ? name : '$name.png';
    return p.join(dir, f);
  }

  static Future<img.Image?> _loadTemplate(String name) async {
    final f = name.endsWith('.png') ? name : '$name.png';
    final subdir = templateSubdir ?? 'trustwallet';

    // rootBundle 먼저 시도 (릴리즈 APK에서 assets 폴더가 올바르게 번들됨)
    try {
      final bytes = await rootBundle.load('assets/data/$subdir/$f');
      return img.decodeImage(bytes.buffer.asUint8List());
    } catch (_) {}

    // documents 경로 fallback (adb push 등으로 복사한 경우)
    try {
      final path = await _templatePath(name);
      final file = File(path);
      if (file.existsSync()) {
        final bytes = await file.readAsBytes();
        return img.decodeImage(bytes);
      }
    } catch (_) {}

    return null;
  }

  /// [이미지 매칭 비활성화] 화면에서 템플릿 찾기 — OpenCV 사용 안 함.
  static Future<(((int x, int y) abs, double confidence, double scale), int? screenHash, (int w, int h)? templateSize)?> findImage(
    String name, {
    double threshold = 0.3,
  }) async {
    return null; // 이미지 매칭 비활성화
    // if (!Platform.isAndroid) return null;
    // final totalStopwatch = Stopwatch()..start();
    // final (w, h) = await _getScreenSize();
    // _log('[캡처] 새 화면 캡처 후 $name 검색');
    // final bytes = await _captureScreen(0, 0, w, h);
    // if (bytes == null || bytes.isEmpty) return null;
    // final screenImg = img.decodeImage(bytes);
    // if (screenImg == null) { totalStopwatch.stop(); _log('[매칭] $name: 스크린 이미지 디코드 실패'); return null; }
    // final template = await _loadTemplate(name);
    // if (template == null) { totalStopwatch.stop(); _log('[템플릿] $name 로드 실패'); return null; }
    // try {
    //   final templatePng = img.encodePng(template);
    //   if (templatePng != null && templatePng.isNotEmpty) {
    //     final openCvResult = await _channel.invokeMethod<Map<Object?, Object?>>('matchTemplate', {
    //       'screenBytes': bytes, 'templateBytes': templatePng, 'threshold': threshold,
    //     });
    //     if (openCvResult != null && openCvResult['found'] == true) {
    //       final x = openCvResult['x'] as num?;
    //       final y = openCvResult['y'] as num?;
    //       final conf = openCvResult['confidence'] as num?;
    //       if (x != null && y != null && conf != null) {
    //         final cw = screenImg.width; final ch = screenImg.height;
    //         final tapX = (cw != w || ch != h) ? (x.toInt() * w / cw).round() : x.toInt();
    //         final tapY = (cw != w || ch != h) ? (y.toInt() * h / ch).round() : y.toInt();
    //         final screenHash = _hashImage(screenImg);
    //         return (((tapX, tapY), conf.toDouble(), 1.0), screenHash, (template.width, template.height));
    //       }
    //     }
    //   }
    // } catch (_) {}
    // return null;
  }

  /// 단계별 기록: 캡처 이미지 저장 — log 폴더 사용 (nexus_automation_log와 동일)
  static bool debugSaveCaptureAndLog = false;
  /// log 폴더 경로 (캡처, steps.log, nexus_automation_log 전부 여기)
  static Future<String> getDebugSaveDirectory() async {
    final dir = await AutomationLogFile.getLogDirectory();
    _log('[log] 경로: $dir');
    return dir;
  }

  static Future<void> _saveStepRecord(String stepName, img.Image capture, int clickX, int clickY) async {
    try {
      final debugDir = await getDebugSaveDirectory();
      final dir = Directory(debugDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final ts = DateTime.now().millisecondsSinceEpoch;
      final filename = 'step_${stepName}_$ts.png';
      final path = p.join(debugDir, filename);

      // 찾은 좌표에 빨간 원 표시 (clickX/clickY가 유효할 때만)
      img.Image toSave = capture;
      final w = capture.width;
      final h = capture.height;
      if (clickX >= 0 && clickX < w && clickY >= 0 && clickY < h) {
        try {
          toSave = capture.clone();
          img.fillCircle(toSave, x: clickX, y: clickY, radius: 25, color: img.ColorRgba8(255, 0, 0, 200));
        } catch (_) {
          toSave = capture;
        }
      }

      final png = img.encodePng(toSave);
      if (png != null && png.isNotEmpty) {
        final file = File(path);
        await file.writeAsBytes(png);
        final logPath = p.join(debugDir, 'steps.log');
        final coordStr = (clickX >= 0 && clickY >= 0) ? '($clickX,$clickY)' : '미발견';
        final line = 'step=$stepName capture=$filename click=$coordStr\n';
        await File(logPath).writeAsString(line, mode: FileMode.append);
        _log('[기록] $stepName click=$coordStr → $path');
      } else {
        _log('[기록] PNG 인코드 실패 (null/empty)');
      }
    } catch (e, st) {
      _log('[기록] 저장 실패: $e');
      if (debugLog != null) debugLog!('저장 실패 상세: $st');
    }
  }

  /// UIAutomator 선택자 맵. first는 여기 없으면 OpenCV로 처리.
  static Map<String, Map<String, String?>>? selectorOverrides;

  // 이미지 매칭 비활성화
  // /// first 전용: OpenCV 템플릿 매칭 후 해당 위치 클릭.
  // static Future<bool> _clickImageByOpenCv(...) async {
  //   final res = await findImage(name, threshold: th);
  //   if (res == null) return false;
  //   final ((abs, _, _), screenHash, _) = res;
  //   final ok = await sendTouch(cx, cy);
  //   ...
  // }
  static Future<bool> _clickImageByOpenCv(
    String name, {
    double? threshold,
    double delaySec = 0.2,
    bool waitScreenChange = true,
  }) async => false;

  /// first: 선택자 있으면 desc contains로 클릭, 없으면 OpenCV. 나머지는 UIAutomator 선택자.
  static Future<bool> clickImage(
    String name, {
    double? threshold,
    double delaySec = 0.2,
    bool waitScreenChange = true,
    bool logStepAndNodes = false,
  }) async {
    if (!Platform.isAndroid) return false;
    final sel = selectorOverrides?[name];
    if (name == 'first' && sel != null &&
        (sel['resourceId'] != null || sel['text'] != null || sel['contentDesc'] != null || sel['className'] != null)) {
      _log('→ first 시도 중... (선택자 desc contains)');
      final (ok, _, screenNodes) = await clickBySelector(
        resourceId: sel['resourceId'],
        text: sel['text'],
        contentDesc: sel['contentDesc'],
        className: sel['className'],
      );
      if (ok) {
        await Future.delayed(Duration(milliseconds: (delaySec * 1000).round()));
        if (waitScreenChange) {
          final hash = await getScreenHash();
          final changed = await waitForScreenChange(hash);
          if (!changed) _log('  (화면변경 미확인, 진행)');
        }
        _log('→ first ✓');
        return true;
      }
      if (screenNodes != null && screenNodes.isNotEmpty) {
        _log('  [first] 화면 노드: $screenNodes');
      }
      _log('→ first ✗');
      return false;
    }
    if (name == 'first') {
      _log('→ first ✗ (선택자 없음, 이미지 매칭 비활성화)');
      return false;
    }
    if (sel == null ||
        (sel['resourceId'] == null && sel['text'] == null && sel['contentDesc'] == null && sel['className'] == null)) {
      _log('→ $name ✗ (선택자 없음)');
      return false;
    }
    _log('→ $name 시도 중...');
    final (ok, _, screenNodes) = await clickBySelector(
      resourceId: sel['resourceId'],
      text: sel['text'],
      contentDesc: sel['contentDesc'],
      className: sel['className'],
    );
    if (!ok && screenNodes != null && screenNodes.isNotEmpty) {
      _log('  [$name] 찾는 조건: res=${sel['resourceId']} text=${sel['text']} desc=${sel['contentDesc']}');
      _log('  [$name] 화면 노드: $screenNodes');
    }
    if (ok) {
      await Future.delayed(Duration(milliseconds: (delaySec * 1000).round()));
      if (waitScreenChange) {
        final hash = await getScreenHash();
        final changed = await waitForScreenChange(hash);
        if (!changed) _log('  (화면변경 미확인, 진행)');
      }
      _log('→ $name ✓');
      return true;
    }
    _log('→ $name ✗ (다음으로 넘어가지 않고 재시도)');
    return false;
  }

  /// UIAutomator 선택자로만 클릭 (AtLeft와 동일 — 선택자 사용 시엔 좌단 오프셋 없음).
  static Future<bool> clickImageAtLeft(
    String name, {
    double? threshold,
    double delaySec = 0.2,
    bool waitScreenChange = true,
  }) async {
    return clickImage(name, threshold: threshold, delaySec: delaySec, waitScreenChange: waitScreenChange);
  }

  /// 선택자 기반 스텝에서 노드 영역 오른쪽 끝으로 탭. first는 선택자 있으면 사용.
  static Future<bool> clickImageAtRight(
    String name, {
    double? threshold,
    double delaySec = 0.2,
    bool waitScreenChange = true,
    bool logStepAndNodes = false,
  }) async {
    if (!Platform.isAndroid) return false;
    if (name == 'first') {
      return clickImage(name, threshold: threshold, delaySec: delaySec, waitScreenChange: waitScreenChange);
    }
    final sel = selectorOverrides?[name];
    if (sel == null ||
        (sel['resourceId'] == null && sel['text'] == null && sel['contentDesc'] == null && sel['className'] == null)) {
      _log('→ $name ✗ (선택자 없음)');
      return false;
    }
    _log('→ $name 시도 중... (오른쪽 탭)');
    final (ok, _, screenNodes) = await clickBySelector(
      resourceId: sel['resourceId'],
      text: sel['text'],
      contentDesc: sel['contentDesc'],
      className: sel['className'],
      tapAtRight: true,
    );
    if (!ok && screenNodes != null && screenNodes.isNotEmpty) {
      _log('  [$name] 찾는 조건: res=${sel['resourceId']} text=${sel['text']} desc=${sel['contentDesc']}');
      _log('  [$name] 화면 노드: $screenNodes');
    }
    if (ok) {
      await Future.delayed(Duration(milliseconds: (delaySec * 1000).round()));
      if (waitScreenChange) {
        final hash = await getScreenHash();
        final changed = await waitForScreenChange(hash);
        if (!changed) _log('  (화면변경 미확인, 진행)');
      }
      _log('→ $name ✓');
      return true;
    }
    _log('→ $name ✗ (다음으로 넘어가지 않고 재시도)');
    return false;
  }

  /// (x,y) 좌표의 접근성 노드로 ACTION_CLICK. dispatchGesture 차단 시 대안
  static Future<bool> sendTouchByNode(int x, int y) async {
    try {
      final ok = await _channel.invokeMethod<bool>('touchByNode', {'x': x, 'y': y});
      _log('[터치노드] ($x,$y) ACTION_CLICK: ${ok ?? false}');
      return ok ?? false;
    } catch (e) {
      _log('[터치노드] ($x,$y) 오류: $e');
      return false;
    }
  }

  /// (x,y)에 터치 전송. 결과는 제스처 콜백(onCompleted/onCancelled) 기준 — true=실행됨, false=취소/실패
  ///
  /// [첫 화면은 되는데 팝업에서만 안 될 때] 확인 방법:
  /// 1. adb logcat -s NexusTouch → onCompleted vs onCancelled 확인
  /// 2. "11개 좌표 모두 onCancelled" → 해당 창에서 제스처 거부 (팝업이 물리 터치만 허용했거나 보안 레이어)
  /// 3. onCompleted가 찍혔는데도 UI 반응 없음 → 제스처는 전달됐지만 앱이 가상 터치 무시(물리만 허용 정책 가능성)
  static Future<bool> sendTouch(int x, int y) async {
    try {
      final ok = await _channel.invokeMethod<bool>('touch', {'x': x, 'y': y});
      final result = ok ?? false;
      _log('[터치] ($x,$y) 콜백결과: $result (true=제스처 실행됨, false=취소/실패)');
      return result;
    } catch (e) {
      _log('[터치] ($x,$y) 오류: $e');
      return false;
    }
  }

  static Future<void> _tap(int x, int y) async {
    await sendTouch(x, y);
  }

  /// 터치만 테스트 (캡처/매칭 없이). 화면 중앙 등 지정 좌표에 한 번 탭.
  static Future<bool> testTouchAt(int x, int y) async {
    if (!Platform.isAndroid) return false;
    _log('[터치테스트] ($x,$y) 전송');
    final ok = await sendTouch(x, y);
    _log('[터치테스트] 결과: $ok');
    return ok;
  }

  /// 캡처만 테스트 (매칭/터치 없이). 원인 파악용.
  static Future<bool> testCapture() async {
    if (!Platform.isAndroid) return false;
    final (w, h) = await _getScreenSize();
    final bytes = await _captureScreen(0, 0, w, h);
    return bytes != null && bytes.isNotEmpty;
  }

  static Future<void> tapAt(int x, int y, [double delaySec = 0.2]) async {
    await sendTouch(x, y);
    await Future.delayed(Duration(milliseconds: (delaySec * 1000).round()));
  }

  static Future<bool> ensurePicDirExists() async {
    final dir = await picsDir;
    try {
      Directory(dir).createSync(recursive: true);
      return true;
    } catch (_) {
      return false;
    }
  }
}
