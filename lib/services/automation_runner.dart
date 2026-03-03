import 'dart:io';
import 'dart:math';
import 'dart:convert';

import 'package:bip39_plus/bip39_plus.dart' as bip39;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'app_launcher.dart';
import 'android_image_matcher.dart';
import 'automation_log_file.dart';
import 'wallet_count_file.dart';

/// SafePal FSM 상태
enum SafePalState {
  first, // 지갑 목록(first) 화면
  password, // 보안 비밀번호 입력 화면
  afterFirst, // 니모닉/그 이후 단계
  unknown, // 판정 불가
}

/// SafePal FSM 액션
enum SafePalAction {
  initializeFromFirst, // first에서 second/third/비번까지 초기 진입
  enterPasswordOnly, // 비밀번호 화면에서 비번만 다시 입력
  skipInit, // 이미 니모닉 이후이므로 init 스킵
  none, // 아무 것도 하지 않음
}

/// Trust Wallet (com.wallet.crypto.trustapp) 플로우
/// 템플릿: data/trustwallet — first, second, third, fourth, phrase1~4, chain,
///         wordinput, wordpaste, wordnext, fail, successPage, wallet, delete, delete2, 0~9
/// UIAutomator 선택자: 아래 맵에 넣으면 해당 스텝에서 이미지 대신 노드 클릭 먼저 시도 (first 이후 터치 차단 우회용)
class AutomationRunner {
  static bool stopFlag = false;
  static String password = '';

  /// SafePal 화면 프로파일 (성공 사이클에서 수집한 노드 시그니처)
  /// FIRST / MNEMONIC / FAIL / SUCCESS 상태별로 nodeDetails 문자열을 누적 저장.
  static final Map<String, Set<String>> _safePalProfiles = {
    'FIRST': <String>{},
    'MNEMONIC': <String>{},
    'FAIL': <String>{},
    'SUCCESS': <String>{},
  };

  /// SafePal 화면 프로파일 저장/로드용 경로
  static Future<String> _safePalProfilesFilePath() async {
    final base = (await getApplicationDocumentsDirectory()).path;
    return p.join(base, 'data', 'safepal_profiles.json');
  }

  /// 디스크에서 SafePal 프로파일을 불러오기 (앱 시작 후 첫 SafePal 실행 시)
  static Future<void> _loadSafePalProfiles() async {
    try {
      final path = await _safePalProfilesFilePath();
      final file = File(path);
      if (!file.existsSync()) return;
      final txt = await file.readAsString();
      if (txt.trim().isEmpty) return;
      final root = jsonDecode(txt) as Map<String, dynamic>;
      root.forEach((key, value) {
        if (value is List) {
          _safePalProfiles[key] = value.map((e) => e.toString()).toSet();
        }
      });
    } catch (_) {
      // 프로파일 로드 실패는 무시 (없으면 새로 수집)
    }
  }

  /// 메모리에 있는 SafePal 프로파일을 디스크에 저장
  static Future<void> _saveSafePalProfiles() async {
    try {
      final path = await _safePalProfilesFilePath();
      final file = File(path);
      final dir = file.parent;
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      final map = <String, List<String>>{};
      _safePalProfiles.forEach((key, set) {
        if (set.isNotEmpty) {
          final list = set.toList()..sort();
          map[key] = list;
        }
      });
      await file.writeAsString(jsonEncode(map));
    } catch (_) {
      // 저장 실패도 무시 (다음 사이클에서 다시 시도)
    }
  }

  // ---------- 테스트용: 숫자만 바꿔서 등록/삭제 횟수 조정 ----------
  static const int testRegisterCount = 1;  // 지갑 등록 성공 목표 (이 개수만 등록 후 삭제로)
  static const int testDeleteCount = 1;   // 삭제 루프에서 삭제할 개수
  // -----------------------------------------------------------------

  /// 스텝 → UIAutomator 선택자. first=OpenCV 이미지매칭, fail=OpenCV만
  static final Map<String, Map<String, String?>> uiautomatorSelectors = {
    // first: 선택자 없음 → OpenCV(first.png) 매칭 후 클릭
    'second': {'resourceId': 'addWalletIconButton'},         // 지갑 추가
    'third': {'resourceId': 'AddExistingWallet'},           // 기존 지갑 추가
    'fourth': {'resourceId': 'secretPhrase'},                // 비밀 문구
    'phrase1': {'resourceId': 'SecretPhraseImportConsentCheck1'},  // 동의 체크1
    'phrase2': {'resourceId': 'SecretPhraseImportConsentCheck2'},  // 동의 체크2
    'phrase3': {'resourceId': 'SecretPhraseImportConsentCheck3'},  // 동의 체크3
    'phrase4': {'resourceId': 'buttonTitle', 'text': '계속하기'},   // 계속하기
    'chain': {'text': 'Tron'},                               // 네트워크 Tron
    'wordinput': {'resourceId': 'secretPhraseField'},        // 비밀 문구 입력 필드
    'wordpaste': {'resourceId': 'pasteButton'},               // 붙여넣기
    'wordnext': {'resourceId': 'restoreWalletButton'},        // 지갑 복원
    'successPage': {'text': '건너뛰기'},                      // 성공 화면
    'success': {'text': '축하합니다'},                         // 성공 메시지
    'wallet': {'resourceId': 'walletRow'},                   // 지갑 행 (삭제 진입)
    'delete': {'resourceId': 'deleteWalletButton'},          // 지갑 삭제
    'delete2': {'resourceId': 'dialogDeleteButton'},         // 삭제 확인 다이얼로그
    '0': {'text': '0'}, '1': {'text': '1'}, '2': {'text': '2'}, '3': {'text': '3'}, '4': {'text': '4'},
    '5': {'text': '5'}, '6': {'text': '6'}, '7': {'text': '7'}, '8': {'text': '8'}, '9': {'text': '9'},
    // fail: 선택자 없음 → OpenCV 이미지 매칭만 사용
  };

  /// SafePal (io.safepal.wallet) — first=Wallet contains 선택자, 나머지 desc 기반
  static final Map<String, Map<String, String?>> safePalSelectors = {
    'first': {'contentDesc': 'Wallet', 'className': 'android.view.View'},  // desc contains Wallet (Wallet01-B2E 등)
    'second': {'contentDesc': '지갑 추가', 'className': 'android.view.View'},
    'third': {'contentDesc': '기존 지갑 추가', 'className': 'android.widget.Button'},
    'paste': {'contentDesc': '불여넣기', 'className': 'android.widget.Button'},
    'next': {'contentDesc': '다음', 'className': 'android.widget.Button'},
    'confirm': {'contentDesc': '지금 가져오기', 'className': 'android.widget.Button'},  // 6자 초과→contains 매칭
    'delete': {'contentDesc': '지우기', 'className': 'android.widget.Button'},
    'delete1': {'contentDesc': '지갑 삭제', 'className': 'android.widget.Button'},
    'delete2': {'contentDesc': '삭제', 'className': 'android.widget.Button'},
    'select': {'contentDesc': 'Mnemonic', 'className': 'android.widget.ImageView'},
    '0': {'contentDesc': '0', 'className': 'android.widget.Button'},
    '1': {'contentDesc': '1', 'className': 'android.widget.Button'},
    '2': {'contentDesc': '2', 'className': 'android.widget.Button'},
    '3': {'contentDesc': '3', 'className': 'android.widget.Button'},
    '4': {'contentDesc': '4', 'className': 'android.widget.Button'},
    '5': {'contentDesc': '5', 'className': 'android.widget.Button'},
    '6': {'contentDesc': '6', 'className': 'android.widget.Button'},
    '7': {'contentDesc': '7', 'className': 'android.widget.Button'},
    '8': {'contentDesc': '8', 'className': 'android.widget.Button'},
    '9': {'contentDesc': '9', 'className': 'android.widget.Button'},
  };

  /// SafePal 화면 노드 프로파일 수집 (메모리 절약을 위해 비활성화)
  static Future<void> _captureSafePalProfile(String state, void Function(String) logLine) async {}

  /// 현재 화면이 어떤 SafePal 상태와 가장 비슷한지 프로파일 기반으로 추정
  static Future<String?> _detectSafePalStateFromProfiles(void Function(String) logLine) async {
    try {
      if (_safePalProfiles.values.every((s) => s.isEmpty)) return null;
      final texts = await _getRecentAccessibilityTexts();
      final details = await AndroidImageMatcher.getNodeDetailsForSelectors();
      print('NodeDetails: $details');
      print('Texts : $texts');
      if (details.isEmpty) return null;
      final current = details.toSet();
      String? bestState;
      int bestScore = 0;
      _safePalProfiles.forEach((state, profile) {
        if (profile.isEmpty) return;
        final score = profile.intersection(current).length;
        if (score > bestScore) {
          bestScore = score;
          bestState = state;
        }
      });
      // 3개 이상 노드가 겹치면 그 상태로 인식 (느슨한 기준)
      if (bestState != null && bestScore >= 3) {
        // logLine('[profile] 현재 화면 상태 추정: $bestState (score=$bestScore)');
        return bestState;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> run({
    required void Function(String text) logLine,
    required void Function(String text) logLineRed,
    required void Function(String phrase) addAttemptedPhrase,
    required void Function(String text) replaceLogLastLine,
    required void Function(String text) setClipboard,
  }) async {
    void dbLog(String s) => logLine(s);
    void dbLogRed(String s) => logLineRed(s);

    if (!Platform.isAndroid) {
      dbLogRed('이 앱은 Android에서만 동작합니다.');
      return;
    }

    stopFlag = false;

    final hasTouch = await AndroidImageMatcher.hasTouchPermission();
    if (!hasTouch) {
      dbLogRed('접근성 권한이 필요합니다. 설정에서 Nexus를 활성화해주세요.');
      return;
    }

    await AndroidImageMatcher.acquireWakeLock();

    try {
      dbLog('1) 화면캡처 권한 팝업에서 "시작" 눌러 허용 (4초 대기)');
      await AndroidImageMatcher.requestScreenPermission();
      await Future.delayed(const Duration(seconds: 4));
      AndroidImageMatcher.debugLog = dbLog;
      final captureOk = await AndroidImageMatcher.testCapture();
      AndroidImageMatcher.debugLog = null;
      if (!captureOk) {
        dbLogRed('화면캡처 실패. 팝업에서 "시작" 눌렀는지 확인 후 다시 시도.');
        return;
      }
      dbLog('화면캡처 OK → Trust Wallet 실행');

      final launched = await AppLauncher.launchTrustWallet();
      if (!launched) {
        dbLogRed('Trust Wallet 앱을 찾을 수 없습니다.');
        return;
      }
      dbLog('Trust Wallet 실행됨. 5초 대기 (전환 대기)');
      await Future.delayed(const Duration(milliseconds: 5000));

      AndroidImageMatcher.debugLog = dbLog;
      AndroidImageMatcher.selectorOverrides = uiautomatorSelectors.isNotEmpty ? uiautomatorSelectors : null;
      if (AndroidImageMatcher.debugSaveCaptureAndLog) {
        final dir = await AndroidImageMatcher.getDebugSaveDirectory();
        dbLog('캡처 기록 ON → log: $dir');
      }
      try {
        await _runFlow(dbLog, dbLogRed, addAttemptedPhrase, replaceLogLastLine, setClipboard);
      } catch (e, st) {
        dbLogRed('오류: $e');
      } finally {
        AndroidImageMatcher.debugLog = null;
      }
      dbLog('작업 종료');
    } finally {
      await AndroidImageMatcher.releaseWakeLock();
    }
  }

  /// SafePal 플로우: [12생성&기억]→[시도]→[실패]재귀 / [성공]기억문구 서버전송+성공로직
  static Future<void> runSafePal({
    required void Function(String text) logLine,
    required void Function(String text) logLineRed,
    required void Function(String phrase) onSuccessPhrase,
    required void Function(String text) replaceLogLastLine,
    required void Function(String text) setClipboard,
  }) async {
    void dbLog(String s) => logLine(s);
    void dbLogRed(String s) => logLineRed(s);

    if (!Platform.isAndroid) {
      dbLogRed('이 앱은 Android에서만 동작합니다.');
      return;
    }

    stopFlag = false;
    _safePalFirstInitDone = false;
    _safePalClickProfiles.clear();
    // 이전 성공 사이클에서 수집된 SafePal 화면 프로파일 로드 (있다면 활용)
    await _loadSafePalProfiles();
    AndroidImageMatcher.templateSubdir = 'app';
    AndroidImageMatcher.selectorOverrides = safePalSelectors;
    await AndroidImageMatcher.ensureAppTemplatesInDocuments();

    final hasTouch = await AndroidImageMatcher.hasTouchPermission();
    if (!hasTouch) {
      dbLogRed('접근성 권한이 필요합니다. 설정에서 Nexus를 활성화해주세요.');
      return;
    }

    await AndroidImageMatcher.acquireWakeLock();

    try {
      AndroidImageMatcher.debugLog = dbLog;
      final launched = await AppLauncher.launchSafePal();
      if (!launched) {
        dbLogRed('SafePal 앱을 찾을 수 없습니다. (io.safepal.wallet)');
        AndroidImageMatcher.debugLog = null;
        return;
      }
      dbLog('SafePal 실행됨. 3초 대기');
      await Future.delayed(const Duration(milliseconds: 3000));

      try {
        await _runSafePalFlow(dbLog, dbLogRed, onSuccessPhrase, setClipboard);
      } catch (e, st) {
        dbLogRed('오류: $e');
      } finally {
        AndroidImageMatcher.debugLog = null;
      }
      dbLog('작업 종료');
    } finally {
      AndroidImageMatcher.templateSubdir = null;
      AndroidImageMatcher.selectorOverrides = null;
      await AndroidImageMatcher.releaseWakeLock();
    }
  }

  static const int _safepalDeleteTarget = 5;

  /// SafePal 텍스트 정규화: zero-width 문자 제거 (W​a​l​l​e​t, 불‍여‍넣‍기 등)
  static String _normalizeText(String s) {
    // U+200B..U+200D, U+FEFF 등 zero-width 계열 제거
    return s.replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), '');
  }

  /// SafePal 클릭 패턴 프로파일 (테스트 모드에서 수집한 데이터 기반)
  static final Map<String, Set<String>> _safePalClickProfiles = {};
  static bool _safePalFirstInitDone = false;

  static Future<String> _safePalClickProfilesFilePath() async {
    final base = (await getApplicationDocumentsDirectory()).path;
    return p.join(base, 'data', 'safepal_click_profiles.json');
  }

  static Future<void> _loadSafePalClickProfiles() async {
    try {
      if (_safePalClickProfiles.isNotEmpty) return;
      // 1) documents/data/safepal_click_profiles.json 에서 로드
      final path = await _safePalClickProfilesFilePath();
      final file = File(path);
      if (file.existsSync()) {
        final txt = await file.readAsString();
        if (txt.trim().isNotEmpty) {
          final root = jsonDecode(txt);
          if (root is Map) {
            root.forEach((key, value) {
              final step = key.toString();
              if (value is List) {
                _safePalClickProfiles[step] =
                    value.map((e) => e.toString()).toSet();
              }
            });
            return;
          }
        }
      }

      // 2) 번들 assets/data/safepal_click_profiles.json 에서 로드 (배포용)
      try {
        final txt = await rootBundle
            .loadString('assets/data/safepal_click_profiles.json');
        if (txt.trim().isNotEmpty) {
          final root = jsonDecode(txt);
          if (root is Map) {
            root.forEach((key, value) {
              final step = key.toString();
              if (value is List) {
                _safePalClickProfiles[step] =
                    value.map((e) => e.toString()).toSet();
              }
            });
          }
        }
      } catch (_) {
        // assets 쪽은 없을 수 있음
      }
    } catch (_) {
      // 프로파일 로드 실패는 무시
    }
  }

  static Future<void> _saveSafePalClickProfiles() async {
    try {
      final path = await _safePalClickProfilesFilePath();
      final file = File(path);
      final dir = file.parent;
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      final map = <String, List<String>>{};
      _safePalClickProfiles.forEach((step, patterns) {
        if (patterns.isNotEmpty) {
          final list = patterns.toList()..sort();
          map[step] = list;
        }
      });
      await file.writeAsString(jsonEncode(map));
    } catch (_) {
      // 저장 실패는 무시
    }
  }

  /// log 폴더의 safepal_clicks.jsonl → safepal_click_profiles.json 으로 변환
  /// 반환값: 생성된 JSON 문자열 (에디터에서 복붙용)
  static Future<String?> buildSafePalClickProfilesFromLog() async {
    try {
      _safePalClickProfiles.clear();
      final logDir = await AutomationLogFile.getLogDirectory();
      final src = File(p.join(logDir, 'safepal_clicks.jsonl'));
      if (!src.existsSync()) return null;
      final lines = await src.readAsLines();
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          final obj = jsonDecode(line);
          if (obj is! Map) continue;
          final step = obj['step']?.toString() ?? '';
          final matchedRaw = obj['matched']?.toString() ?? '';
          if (step.isEmpty || matchedRaw.isEmpty) continue;
          // desc:... 부분만 뽑아서 패턴 단순화
          final matched = _extractClickPattern(step, matchedRaw);
          if (matched.isEmpty) continue;
          final set =
              _safePalClickProfiles.putIfAbsent(step, () => <String>{});
          set.add(matched);
        } catch (_) {
          // 개별 라인 에러 무시
        }
      }
      final map = <String, List<String>>{};
      _safePalClickProfiles.forEach((step, patterns) {
        if (patterns.isNotEmpty) {
          final list = patterns.toList()..sort();
          map[step] = list;
        }
      });
      final jsonStr = jsonEncode(map);
      await _saveSafePalClickProfiles();
      return jsonStr;
    } catch (_) {
      // 전체 실패도 무시 (개발용)
      return null;
    }
  }

  /// safepal_clicks.jsonl 의 matched 문자열에서 desc 기반 간단 패턴만 추출
  static String _extractClickPattern(String step, String matchedRaw) {
    var s = _normalizeText(matchedRaw);
    final idx = s.indexOf('desc:');
    if (idx >= 0) {
      s = s.substring(idx + 'desc:'.length);
    }
    // 줄바꿈/클릭 여부 등 잘라내기
    final nl = s.indexOf('\n');
    if (nl >= 0) s = s.substring(0, nl);
    final bracket = s.indexOf('[');
    if (bracket >= 0) s = s.substring(0, bracket);
    s = s.trim();
    if (s.isEmpty) return '';

    // 숫자 키(0~9)는 비밀번호 입력 전용이라 상태 인식에는 사용하지 않음
    if (int.tryParse(step) != null) {
      return '';
    }
    // first 스텝은 WalletXX → "Wallet" 으로 일반화
    if (step == 'first' && s.startsWith('Wallet')) {
      return 'Wallet';
    }
    return s;
  }

  /// 최근 N번의 접근성 텍스트 중 "마지막으로 안정된" 스냅샷을 가져온다.
  static Future<List<String>> _getRecentAccessibilityTexts({
    int tries = 3,
    int delayMs = 80,
  }) async {
    for (var i = 0; i < tries; i++) {
      try {
        final texts = await AndroidImageMatcher.getAccessibilityNodeTexts();
        if (texts.isNotEmpty) {
          return texts;
        }
      } catch (_) {
        // 개별 호출 실패는 무시하고 다음 시도
      }
      if (i < tries - 1) {
        await Future.delayed(Duration(milliseconds: delayMs));
      }
    }
    return <String>[];
  }

  /// 현재 SafePal의 상위 상태(first / afterFirst)를 판정
  static Future<SafePalState> _detectSafePalState(
    void Function(String) logLine,
  ) async {
    try {
      // 현재 화면의 노드 상세(nodeDetails)를 기반으로 상태를 판정한다.
      final details = await AndroidImageMatcher.getNodeDetailsForSelectors();
      final norm = details.map(_normalizeText).toList();
      final sample = norm.take(10).join(' || ');
      logLine('[state] nodeDetails: $sample');

      final hasWallet = norm.any((t) => t.contains('Wallet'));
      final hasMnemonicWord = norm.any((t) => t.contains('불여넣기'));
      final hasNext = norm.any((t) => t.contains('다음'));
      final hasConfirmMnemonic = norm.any((t) => t.contains('지금 가져오기'));
      final hasBankCoin = norm.any(
        (t) => t.contains('Bank') || t.contains('Coin') || t.contains('bank') || t.contains('coin'),
      );
      final hasPasswordPrompt = norm.any(
        (t) =>
            t.contains('보안 비밀번호를 입력하시기 바랍니다') ||
            t.contains('보안 비밀번호') ||
            t.contains('비밀번호'),
      );

      logLine(
        '[state] features: '
        'hasWallet=$hasWallet, '
        'hasMnemonicWord=$hasMnemonicWord, '
        'hasNext=$hasNext, '
        'hasConfirmMnemonic=$hasConfirmMnemonic, '
        'hasBankCoin=$hasBankCoin, '
        'hasPasswordPrompt=$hasPasswordPrompt',
      );
      logLine(
        '[state] targets: '
        'first=((Wallet || Bank/Coin) && !불여넣기), '
        'password=(보안 비밀번호*), '
        'mnemonic=(불여넣기 || (다음 && 지금 가져오기)), '
        'successLike=(Bank/Coin)',
      );

      // 1) 지갑 목록(first) / 지갑 자산(Bank/Coin) 화면인지
      //    Wallet 또는 Bank/Coin 텍스트 있고, 불여넣기는 없는 경우
      if ((hasWallet || hasBankCoin) && !hasMnemonicWord) {
        logLine('[state] classify=first');
        return SafePalState.first;
      }

      // 2) 비밀번호 입력 화면인지
      if (hasPasswordPrompt) {
        logLine('[state] classify=password');
        return SafePalState.password;
      }

      // 3) 니모닉 입력/확인 단계인지
      if (hasMnemonicWord || (hasNext && hasConfirmMnemonic)) {
        logLine('[state] classify=afterFirst');
        return SafePalState.afterFirst;
      }

      // 4) 어떤 상태로도 분류되지 않으면 unknown
      logLine('[state] classify=unknown');
      return SafePalState.unknown;
    } catch (_) {
      return SafePalState.unknown;
    }
  }

  /// 상태에 따라 어떤 init 액션을 수행할지 결정
  static SafePalAction _decideSafePalNextAction(SafePalState state) {
    switch (state) {
      case SafePalState.first:
        return SafePalAction.initializeFromFirst;
      case SafePalState.password:
        return SafePalAction.enterPasswordOnly;
      case SafePalState.afterFirst:
        return SafePalAction.skipInit;
      case SafePalState.unknown:
      default:
        return SafePalAction.none;
    }
  }

  /// 선택된 액션을 실제로 수행 (First부터 니모닉 루프 진입 전까지의 초기 단계 전담)
  static Future<bool> _performSafePalAction(
    SafePalState state,
    SafePalAction action,
    void Function(String) logLine,
    void Function(String) logLineRed,
    double clickDelay,
  ) async {
    if (stopFlag) return false;

    switch (action) {
      case SafePalAction.initializeFromFirst:
        logLine('--- SafePal first (OpenCV) ---');
        if (!await _retryStep(
          'first',
          () => AndroidImageMatcher.clickImage(
            'first',
            threshold: 0.3,
            delaySec: clickDelay,
            waitScreenChange: false,
          ),
          logLine,
          logLineRed,
        )) {
          await Future.delayed(const Duration(milliseconds: 300));
          return false;
        }
        await Future.delayed(const Duration(milliseconds: 200));
        // first 화면 프로파일 수집
        await _captureSafePalProfile('FIRST', logLine);

        logLine('--- second, third ---');
        if (!await _retryStep(
          'second',
          () => AndroidImageMatcher.clickImage(
            'second',
            threshold: 0.3,
            delaySec: clickDelay,
            waitScreenChange: false,
          ),
          logLine,
          logLineRed,
        )) {
          await Future.delayed(const Duration(milliseconds: 300));
          return false;
        }
        if (stopFlag) return false;
        if (!await _retryStep(
          'third',
          () => AndroidImageMatcher.clickImage(
            'third',
            threshold: 0.3,
            delaySec: clickDelay,
            waitScreenChange: false,
          ),
          logLine,
          logLineRed,
        )) {
          await Future.delayed(const Duration(milliseconds: 300));
          return false;
        }
        await Future.delayed(const Duration(milliseconds: 200));

        if (password.isNotEmpty) {
          logLine('--- 비밀번호 ---');
          if (!await _clickPasswordDigits(logLine)) {
            logLineRed('→ 비밀번호 ✗');
            await Future.delayed(const Duration(milliseconds: 300));
            return false;
          }
          await Future.delayed(const Duration(milliseconds: 150));
        }
        return true;

      case SafePalAction.enterPasswordOnly:
        // 비밀번호 입력 화면에서는 first/second/third를 다시 누르지 않고
        // 비밀번호만 재입력 시도
        logLine('--- 비밀번호(재입력만) ---');
        if (password.isEmpty) {
          return true;
        }
        final ok = await _clickPasswordDigits(logLine);
        await Future.delayed(const Duration(milliseconds: 400));
        if (ok) {
          logLine('→ 비밀번호 ✓ (재입력)');
          return true;
        } else {
          logLineRed('→ 비밀번호 ✗ (재입력 실패, 재시도 예정)');
          return false;
        }

      case SafePalAction.skipInit:
        // 이미 니모닉 단계 이후라면 init(first/second/third/비번)을 스킵
        logLine('--- init 스킵 (이미 니모닉/그 이후 단계로 판단) ---');
        return true;

      case SafePalAction.none:
      default:
        logLine('--- SafePal 상태를 알 수 없음 (init 스킵) ---');
        return true;
    }
  }

  /// SafePal: 지갑 목록(first) 화면인지 — Wallet 노드 있고, 불여넣기 없음
  static Future<bool> _isOnSafePalFirstScreen(void Function(String) logLine) async {
    try {
      final details = await AndroidImageMatcher.getNodeDetailsForSelectors();
      final norm = details.map(_normalizeText).toList();
      final hasMnemonic = norm.any((t) => t.contains('불여넣기'));
      if (hasMnemonic) return false;
      final hasWalletOrBankCoin = norm.any(
        (t) =>
            t.contains('Wallet') ||
            t.contains('Bank') ||
            t.contains('Coin') ||
            t.contains('bank') ||
            t.contains('coin'),
      );
      if (hasWalletOrBankCoin) {
        logLine('→ first 화면 감지 (Wallet/Bank/Coin 텍스트)');
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// SafePal: 확인 모달(지금 지갑을 가져오시겠습니까?) 화면인지
  /// 취소 + "지금"과 "가져오기"를 모두 포함하는 텍스트가 있을 때 true
  static Future<bool> _isOnSafePalConfirmDialog() async {
    try {
      final texts = await AndroidImageMatcher.getAccessibilityNodeTexts();
      final hasCancel = texts.any((t) => t.contains('취소'));
      if (!hasCancel) return false;
      final hasConfirmText = texts.any((t) => t.contains('지금') && t.contains('가져오기'));
      return hasConfirmText;
    } catch (_) {
      return false;
    }
  }

  /// SafePal: 니모닉 입력 스텝 화면인지 — 불여넣기/다음/가져오기 있어야 delete·paste 가능
  static Future<bool> _isOnSafePalMnemonicInputScreen() async {
    try {
      final texts = await _getRecentAccessibilityTexts();
      final hasPaste = texts.any((t) => t.contains('불여넣기'));
      final hasNext = texts.any((t) => t.contains('다음'));
      final hasConfirm = texts.any((t) => t.contains('지금 가져오기'));
      return hasPaste || (hasNext && hasConfirm);
    } catch (_) {
      return false;
    }
  }

  /// SafePal: 보안 비밀번호 입력 화면인지
  static Future<bool> _isOnSafePalPasswordScreen() async {
    try {
      final texts = await _getRecentAccessibilityTexts();
      final hasPrompt = texts.any(
        (t) =>
            t.contains('보안 비밀번호를 입력하시기 바랍니다') ||
            t.contains('보안 비밀번호') ||
            t.contains('비밀번호'),
      );
      // 숫자 패드(0~9 버튼)가 화면에 함께 있는지 대략 확인
      final hasDigitButtons = texts.any(
        (t) => t.contains('0') && t.contains('1') && t.contains('2'),
      );
      return hasPrompt && hasDigitButtons;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _runSafePalFlow(
    void Function(String) logLine,
    void Function(String) logLineRed,
    void Function(String) onSuccessPhrase,
    void Function(String) setClipboard,
  ) async {
    int successCount = 0;
    String currentPhrase = '';

    // SafePal 니모닉 루프: 너무 튀지 않게 약간 여유를 둔 속도
    const clickDelay = 0.08;
    const fastClick = true; // waitScreenChange 없이 빠른 연속 클릭
    while (!stopFlag) {
      // 0) 최초 1회는 상태 인식 없이 first만 강제로 실행해서
      //    지갑 목록 화면으로 진입하도록 한다.
      if (!_safePalFirstInitDone) {
        logLine('--- SafePal init: first ---');
        final okFirst = await _retryStep(
          'first',
          () => AndroidImageMatcher.clickImage(
            'first',
            threshold: 0.3,
            delaySec: clickDelay,
            waitScreenChange: false,
          ),
          logLine,
          logLineRed,
        );
        if (!okFirst) {
          await Future.delayed(const Duration(milliseconds: 500));
          continue;
        }
        _safePalFirstInitDone = true;
        await Future.delayed(const Duration(milliseconds: 300));
        // first 한 번만 누르고, 나머지는 전부 화면 인식 기반으로 처리
        continue;
      }


      // 1) 현재 화면 상태(FIRST / PASSWORD / AFTER_FIRST / UNKNOWN)를 노드 기반으로 판정하고,
      //    그에 맞는 액션(first/second/third/비밀번호 스킵/재입력 등)을 수행
      final state = await _detectSafePalState(logLine);
      if (state == SafePalState.unknown) {
        // 화면 텍스트를 제대로 못 읽은 상태이므로, 아무 것도 하지 말고
        // 잠깐 대기 후 다시 화면 상태를 체크한다.
        await Future.delayed(const Duration(milliseconds: 300));
        continue;
      }
      final action = _decideSafePalNextAction(state);
      final initOk = await _performSafePalAction(
        state,
        action,
        logLine,
        logLineRed,
        clickDelay,
      );
      if (!initOk) {
        // init 단계(first/second/third/비번)에서 실패하면 이번 사이클만 스킵하고 다시 시도
        await Future.delayed(const Duration(milliseconds: 800));
        continue;
      }

      // [12생성 & 기억]
      currentPhrase = (await _getNextPhrase()) ?? '';
      if (currentPhrase.isEmpty) {
        logLine('wordlist 없음');
        return;
      }
      setClipboard(currentPhrase);
      await Future.delayed(const Duration(milliseconds: 25));
       // 니모닉 입력 화면 프로파일 수집
      await _captureSafePalProfile('MNEMONIC', logLine);

      logLine('--- 니모닉: paste, next, confirm ---');
      int retriesForCurrent = 0;
      bool pasteNextConfirmOk = false;
      for (int attempt = 0; attempt < 30 && !stopFlag && !pasteNextConfirmOk; attempt++) {
        if (attempt > 0) {
          logLine('→ 재시도 $attempt: delete → paste → next → confirm');
          if (await AndroidImageMatcher.clickImage('delete', threshold: 0.3, delaySec: clickDelay, waitScreenChange: !fastClick)) {
            await Future.delayed(const Duration(milliseconds: 60));
          }
          setClipboard(currentPhrase);
          await Future.delayed(const Duration(milliseconds: 40));
        }

        // 만약 화면이 꼬여서 이미 확인 모달(지금 지갑을 가져오시겠습니까?)이 떠 있다면,
        // paste/next 대신 confirm만 눌러서 진행
        if (await _isOnSafePalConfirmDialog()) {
          logLine('→ paste/next 단계지만 확인 모달 감지 → confirm');
          if (!await _retryStep('confirm', () => AndroidImageMatcher.clickImage('confirm', threshold: 0.3, delaySec: clickDelay, waitScreenChange: !fastClick), logLine, logLineRed)) {
            await Future.delayed(const Duration(milliseconds: 400));
            continue;
          }
          pasteNextConfirmOk = true;
          break;
        }

        if (!await _retryStep('paste', () => AndroidImageMatcher.clickImage('paste', threshold: 0.3, delaySec: clickDelay, waitScreenChange: !fastClick), logLine, logLineRed)) {
          if (await _isOnSafePalFirstScreen(logLine)) break;
          await Future.delayed(const Duration(milliseconds: 400));
          continue;
        }
        await Future.delayed(const Duration(milliseconds: 70));
        if (stopFlag) break;
        if (!await _retryStep('next', () => AndroidImageMatcher.clickImage('next', threshold: 0.3, delaySec: clickDelay, waitScreenChange: !fastClick), logLine, logLineRed)) {
          if (await _isOnSafePalFirstScreen(logLine)) break;
          await Future.delayed(const Duration(milliseconds: 400));
          continue;
        }
        await Future.delayed(const Duration(milliseconds: 500));
        if (stopFlag) break;
        if (!await _retryStep('confirm', () => AndroidImageMatcher.clickImage('confirm', threshold: 0.3, delaySec: clickDelay, waitScreenChange: !fastClick), logLine, logLineRed)) {
          if (await _isOnSafePalFirstScreen(logLine)) break;
          await Future.delayed(const Duration(milliseconds: 400));
          continue;
        }
        pasteNextConfirmOk = true;
      }
      if (!pasteNextConfirmOk || stopFlag) continue;
      await Future.delayed(const Duration(milliseconds: 260)); // confirm 후 화면 안정화

      const failKeywords = ['지우기'];
      const successKeywords = ['Bank', 'Coin', 'bank', 'coin'];

      while (!stopFlag) {
        await Future.delayed(const Duration(milliseconds: 100));

        final result = await AndroidImageMatcher.checkScreenKeywords(
          failKeywords: failKeywords,
          successKeywords: successKeywords,
        );

        if (result == 'fail') {
          // fail 화면 프로파일 수집
          await _captureSafePalProfile('FAIL', logLine);
          retriesForCurrent++;
          if (retriesForCurrent == 1) {
            logLine('→ fail (빠른 실패) → 같은 문구 한 번 더 시도');
          } else {
            logLine('→ fail → 재귀 (새 문구 시도)');
          }
          if (retriesForCurrent > 1) {
            final nextPhrase = await _getNextPhrase();
            if (nextPhrase != null && nextPhrase.isNotEmpty) currentPhrase = nextPhrase;
          }
          setClipboard(currentPhrase);
          await Future.delayed(const Duration(milliseconds: 40));
          if (!await AndroidImageMatcher.clickImage('delete', threshold: 0.3, delaySec: clickDelay, waitScreenChange: !fastClick)) {
            logLine('→ delete ✗');
            await Future.delayed(const Duration(milliseconds: 300));
            continue;
          }
          await Future.delayed(const Duration(milliseconds: 60));
          if (!await AndroidImageMatcher.clickImage('paste', threshold: 0.3, delaySec: clickDelay, waitScreenChange: !fastClick)) {
            logLine('→ paste ✗');
            await Future.delayed(const Duration(milliseconds: 300));
            continue;
          }
          await Future.delayed(const Duration(milliseconds: 60));
          if (!await AndroidImageMatcher.clickImage('next', threshold: 0.3, delaySec: clickDelay, waitScreenChange: !fastClick)) {
            logLine('→ next ✗');
            await Future.delayed(const Duration(milliseconds: 300));
            continue;
          }
          await Future.delayed(const Duration(milliseconds: 500)); // next 후 인식/전환 대기
          if (!await AndroidImageMatcher.clickImage('confirm', threshold: 0.3, delaySec: clickDelay, waitScreenChange: !fastClick)) {
            logLine('→ confirm ✗');
            await Future.delayed(const Duration(milliseconds: 400));
            continue;
          }
          await Future.delayed(const Duration(milliseconds: 220));
          continue;
        }

        if (result == 'success') {
          // success 화면 프로파일 수집
          await _captureSafePalProfile('SUCCESS', logLine);
          logLine('→ success (Bank/Coin 화면)');
          onSuccessPhrase(currentPhrase);
          successCount++;
          await WalletCountFile.increment();
          logLine('→ successCount=$successCount');
          break;
        }

        if (await _isOnSafePalFirstScreen(logLine)) {
          logLine('→ first 화면 감지 → outer 리셋');
          break;
        }

        // none 상태: 삭제 버튼 유무 + 프로파일 기반 상태 추정으로 분기
        final texts = await AndroidImageMatcher.getAccessibilityNodeTexts();
        final hasDelete = texts.any((t) => t.contains('지우기'));
        final profState = await _detectSafePalStateFromProfiles(logLine) ?? '';

        if (hasDelete || profState == 'FAIL') {
          // 삭제 버튼이 보이거나 FAIL 프로파일과 유사하면 delete → paste → next → confirm
          logLine('→ none → delete로 진행');
          retriesForCurrent++;
          if (retriesForCurrent > 1) {
            final nextPhrase = await _getNextPhrase();
            if (nextPhrase != null && nextPhrase.isNotEmpty) currentPhrase = nextPhrase;
          }
          setClipboard(currentPhrase);
          await Future.delayed(const Duration(milliseconds: 40));
          if (!await AndroidImageMatcher.clickImage('delete', threshold: 0.3, delaySec: clickDelay, waitScreenChange: !fastClick)) {
            await Future.delayed(const Duration(milliseconds: 300));
            continue;
          }
          await Future.delayed(const Duration(milliseconds: 60));
          if (!await AndroidImageMatcher.clickImage('paste', threshold: 0.3, delaySec: clickDelay, waitScreenChange: !fastClick)) {
            await Future.delayed(const Duration(milliseconds: 300));
            continue;
          }
          await Future.delayed(const Duration(milliseconds: 60));
          if (!await AndroidImageMatcher.clickImage('next', threshold: 0.3, delaySec: clickDelay, waitScreenChange: !fastClick)) {
            await Future.delayed(const Duration(milliseconds: 300));
            continue;
          }
          await Future.delayed(const Duration(milliseconds: 500));
          if (!await AndroidImageMatcher.clickImage('confirm', threshold: 0.3, delaySec: clickDelay, waitScreenChange: !fastClick)) {
            await Future.delayed(const Duration(milliseconds: 400));
            continue;
          }
          await Future.delayed(const Duration(milliseconds: 220));
          continue;
        } else {
          // 삭제 버튼이 없고 FAIL 프로파일도 아니면, 현재 화면이 어떤 단계인지 다시 보고 필요한 액션만 수행
          final texts2 = await AndroidImageMatcher.getAccessibilityNodeTexts();
          final onConfirmDialog = await _isOnSafePalConfirmDialog();
          final hasPaste = texts2.any((t) => t.contains('불여넣기'));
          final hasNext = texts2.any((t) => t.contains('다음'));

          if (onConfirmDialog) {
            // 이미 "지금 지갑을 가져오시겠습니까?" 모달이면 confirm만 누른다
            logLine('→ none(삭제X) + 확인 모달 → confirm');
            if (!await AndroidImageMatcher.clickImage('confirm', threshold: 0.3, delaySec: clickDelay, waitScreenChange: !fastClick)) {
              await Future.delayed(const Duration(milliseconds: 400));
              continue;
            }
            await Future.delayed(const Duration(milliseconds: 220));
            continue;
          } else if (!hasPaste && hasNext) {
            // 불여넣기 없이 "다음"만 있으면 이미 문구가 들어간 상태로 보고 next → confirm만 시도
            logLine('→ none(삭제X) + next만 있음 → next/confirm');
            if (!await AndroidImageMatcher.clickImage('next', threshold: 0.3, delaySec: clickDelay, waitScreenChange: !fastClick)) {
              await Future.delayed(const Duration(milliseconds: 400));
              continue;
            }
            await Future.delayed(const Duration(milliseconds: 500));
            if (!await AndroidImageMatcher.clickImage('confirm', threshold: 0.3, delaySec: clickDelay, waitScreenChange: !fastClick)) {
              await Future.delayed(const Duration(milliseconds: 400));
              continue;
            }
            await Future.delayed(const Duration(milliseconds: 220));
            continue;
          } else {
            // 일반적인 니모닉 입력 화면: paste → next → confirm 순차 시도
            logLine('→ none (삭제 버튼 없음) → paste/next/confirm');
            setClipboard(currentPhrase);
            await Future.delayed(const Duration(milliseconds: 40));
            if (!await AndroidImageMatcher.clickImage('paste', threshold: 0.3, delaySec: clickDelay, waitScreenChange: !fastClick)) {
              await Future.delayed(const Duration(milliseconds: 300));
              continue;
            }
            await Future.delayed(const Duration(milliseconds: 70));
            if (!await AndroidImageMatcher.clickImage('next', threshold: 0.3, delaySec: clickDelay, waitScreenChange: !fastClick)) {
              await Future.delayed(const Duration(milliseconds: 400));
              continue;
            }
            await Future.delayed(const Duration(milliseconds: 500));
            if (!await AndroidImageMatcher.clickImage('confirm', threshold: 0.3, delaySec: clickDelay, waitScreenChange: !fastClick)) {
              await Future.delayed(const Duration(milliseconds: 400));
              continue;
            }
            await Future.delayed(const Duration(milliseconds: 220));
            continue;
          }
        }
      }

      if (successCount >= _safepalDeleteTarget) {
        logLine('--- delete loop $_safepalDeleteTarget회 ---');
        int deleted = 0;
        int safety = _safepalDeleteTarget * 6; // 안전장치: 각 삭제당 최대 몇 번까지 재시도

        while (deleted < _safepalDeleteTarget && !stopFlag && safety-- > 0) {
          logLine('→ 삭제 ${deleted + 1}/$_safepalDeleteTarget (시도)');

          // 삭제 시퀀스: first → select → delete1 → delete2 → 비밀번호
          final okFirst = await _retryStep(
            'first',
            () => AndroidImageMatcher.clickImage(
              'first',
              threshold: 0.3,
              delaySec: clickDelay,
              waitScreenChange: false,
            ),
            logLine,
            logLineRed,
          );
          if (!okFirst) {
            await Future.delayed(const Duration(milliseconds: 300));
            continue;
          }
          await Future.delayed(const Duration(milliseconds: 250));

          final okSelect = await AndroidImageMatcher.clickImageAtRight(
            'select',
            threshold: 0.3,
            delaySec: clickDelay,
            waitScreenChange: false,
          );
          if (!okSelect) {
            await Future.delayed(const Duration(milliseconds: 300));
            continue;
          }
          await Future.delayed(const Duration(milliseconds: 250));

          final okDel1 = await AndroidImageMatcher.clickImage(
            'delete1',
            threshold: 0.3,
            delaySec: clickDelay,
            waitScreenChange: false,
          );
          if (!okDel1) {
            await Future.delayed(const Duration(milliseconds: 300));
            continue;
          }
          await Future.delayed(const Duration(milliseconds: 250));

          final okDel2 = await AndroidImageMatcher.clickImage(
            'delete2',
            threshold: 0.3,
            delaySec: clickDelay,
            waitScreenChange: false,
          );
          if (!okDel2) {
            await Future.delayed(const Duration(milliseconds: 300));
            continue;
          }
          await Future.delayed(const Duration(milliseconds: 250));

          final pwdOk = await _clickPasswordDigits(logLine);
          await Future.delayed(const Duration(milliseconds: 400));
          if (!pwdOk) {
            logLine('→ 비밀번호 ✗ (삭제 실패, 재시도)');
            continue;
          }

          deleted++;
          successCount--;
          logLine('→ 삭제 성공: $deleted/$_safepalDeleteTarget');
        }

        // 삭제 루프 전체가 끝난 뒤에는 first로 돌아가기 전에 넉넉히 대기
        await Future.delayed(const Duration(milliseconds: 600));
      }

      // 한 사이클(first → 니모닉 루프 → (필요시) 삭제)이 끝난 뒤에는
      // 다음 first 진입 전에 약간의 텀을 둬서 화면 전환/로딩을 기다림
      await Future.delayed(const Duration(milliseconds: 250));
    }
  }

  static Future<void> _runFlow(
    void Function(String) logLine,
    void Function(String) logLineRed,
    void Function(String) addAttemptedPhrase,
    void Function(String) replaceLogLastLine,
    void Function(String) setClipboard,
  ) async {
    bool passwordDone = false;
    while (!stopFlag) {
      logLine('--- init 시작 ---');
      if (!passwordDone) {
        while (!stopFlag && !await _runPasswordBeforeFirst(logLine)) {
          await Future.delayed(const Duration(milliseconds: 300));
        }
        if (stopFlag) break;
        passwordDone = true;
      }
      if (!await _runInit(logLine, logLineRed)) {
        logLine('→ init ✗ (first~fourth 중 실패, init만 재시도)');
        await Future.delayed(const Duration(milliseconds: 500));
        continue;
      }
      if (!await _runPhraseChain(logLine, logLineRed)) {
        logLine('→ phrase/chain ✗');
        await Future.delayed(const Duration(milliseconds: 500));
        continue;
      }

      int successCount = 0;
      bool firstTimeInLoop = true;

      while (!stopFlag) {
        logLine('→ 키보드 숨김');
        await AndroidImageMatcher.pressBack();
        await Future.delayed(const Duration(milliseconds: 300));

        if (firstTimeInLoop) {
          logLine('--- 니모닉 입력 (최초 1회) ---');
          final phrase = await _getNextPhrase();
          if (phrase == null || phrase.isEmpty) {
            logLine('wordlist 없음${AutomationRunner.wordlistLoadError != null ? " — ${AutomationRunner.wordlistLoadError}" : ""}');
            return;
          }
          setClipboard(phrase);
          addAttemptedPhrase(phrase);
          await Future.delayed(const Duration(milliseconds: 100));

          if (!await AndroidImageMatcher.clickImage('wordinput', threshold: 0.3, delaySec: 0.3)) {
            logLineRed('→ wordinput ✗');
            break;
          }
          await Future.delayed(const Duration(milliseconds: 200));
          if (!await AndroidImageMatcher.clickImage('wordpaste', threshold: 0.3, delaySec: 0.3)) {
            logLineRed('→ wordpaste ✗');
            break;
          }
          await Future.delayed(const Duration(milliseconds: 200));
          if (!await AndroidImageMatcher.clickImage('wordnext', threshold: 0.3, delaySec: 0.3)) {
            logLineRed('→ wordnext ✗');
            break;
          }
          firstTimeInLoop = false;
          await Future.delayed(const Duration(milliseconds: 600));
          continue;
        }

        await Future.delayed(const Duration(milliseconds: 400));
        logLine('→ fail 확인 중... (이미지 매칭 비활성화)');
        // final failFound = await AndroidImageMatcher.findImage('fail', threshold: 0.3);
        const failFound = null; // 이미지 매칭 비활성화
        if (failFound != null) {
          logLine('→ fail ✓ (새 니모닉 시도)');
          await AndroidImageMatcher.selectAll();
          await Future.delayed(const Duration(milliseconds: 150));
          final phrase = await _getNextPhrase();
          if (phrase == null || phrase.isEmpty) break;
          setClipboard(phrase);
          addAttemptedPhrase(phrase);
          await Future.delayed(const Duration(milliseconds: 100));
          if (!await AndroidImageMatcher.clickImage('wordpaste', threshold: 0.3, delaySec: 0.3)) break;
          await Future.delayed(const Duration(milliseconds: 200));
          if (!await AndroidImageMatcher.clickImage('wordnext', threshold: 0.3, delaySec: 0.3)) break;
          await Future.delayed(const Duration(milliseconds: 600));
          continue;
        }

        logLine('→ successPage/success 확인 중...');
        final texts = await AndroidImageMatcher.getAccessibilityNodeTexts();
        final onSuccessPage = texts.any((t) => t.contains('건너뛰기'));
        if (onSuccessPage) {
          if (await AndroidImageMatcher.clickImage('successPage', delaySec: 0.5)) {
            await Future.delayed(const Duration(milliseconds: 500));
            await WalletCountFile.increment();
            successCount++;
            logLine('→ successPage ✓ (지갑 $successCount/$testRegisterCount, 삭제 $testDeleteCount회)');
            await _runDeleteLoop(logLine, testDeleteCount);
            passwordDone = false;
            if (successCount >= testRegisterCount) {
              logLine('→ 테스트 완료 (등록 $testRegisterCount, 삭제 $testDeleteCount)');
              return; // 한 사이클만 하고 종료
            }
            break;
          }
        }

        final onSuccess = texts.any((t) => t.contains('축하합니다'));
        if (onSuccess) {
          successCount++;
          logLine('→ success ✓ (누적 $successCount)');
          await AndroidImageMatcher.clickImage('success', delaySec: 0.3);
          await Future.delayed(const Duration(milliseconds: 400));
          continue;
        }

        logLine('→ 대기 후 재확인');
        await Future.delayed(const Duration(milliseconds: 500));
      }

      await Future.delayed(const Duration(milliseconds: 500));
    }
  }

  static Future<bool> _runPasswordBeforeFirst(void Function(String) logLine) async {
    if (stopFlag || password.isEmpty) return true;
    logLine('→ 비밀번호 입력 중...');
    final ok = await _clickPasswordDigits(logLine);
    await Future.delayed(const Duration(milliseconds: 400));
    if (ok) {
      logLine('→ 비밀번호 ✓');
    } else {
      logLine('→ 비밀번호 ✗ (재시도)');
    }
    return ok;
  }

  static const int _maxStepRetries = 15;

  static Future<bool> _retryStep(String name, Future<bool> Function() tap, void Function(String) logLine, void Function(String) logLineRed, {int retryDelayMs = 120}) async {
    for (var i = 0; i < _maxStepRetries && !stopFlag; i++) {
      if (await tap()) return true;
      logLineRed('→ $name ✗ (${i + 1}/$_maxStepRetries 재시도)');
      await Future.delayed(Duration(milliseconds: retryDelayMs));
    }
    return false;
  }

  static Future<bool> _runInit(void Function(String) logLine, void Function(String) logLineRed) async {
    if (stopFlag) return false;
    if (!await _retryStep('first', () => AndroidImageMatcher.clickImage('first', threshold: 0.3, delaySec: 0.4), logLine, logLineRed)) return false;
    if (stopFlag) return false;
    if (!await _retryStep('second', () => AndroidImageMatcher.clickImage('second', threshold: 0.3, delaySec: 0.4), logLine, logLineRed)) return false;
    if (stopFlag) return false;
    if (!await _retryStep('third', () => AndroidImageMatcher.clickImage('third', threshold: 0.3, delaySec: 0.4), logLine, logLineRed)) return false;
    if (stopFlag) return false;
    if (!await _retryStep('fourth', () => AndroidImageMatcher.clickImage('fourth', threshold: 0.3, delaySec: 0.4), logLine, logLineRed)) return false;
    return true;
  }

  static Future<bool> _runPhraseChain(void Function(String) logLine, void Function(String) logLineRed) async {
    if (stopFlag) return false;
    if (!await _retryStep('phrase1', () => AndroidImageMatcher.clickImageAtLeft('phrase1', threshold: 0.3, delaySec: 0.3), logLine, logLineRed)) return false;
    if (stopFlag) return false;
    if (!await _retryStep('phrase2', () => AndroidImageMatcher.clickImageAtLeft('phrase2', threshold: 0.3, delaySec: 0.3), logLine, logLineRed)) return false;
    if (stopFlag) return false;
    if (!await _retryStep('phrase3', () => AndroidImageMatcher.clickImageAtLeft('phrase3', threshold: 0.3, delaySec: 0.3), logLine, logLineRed)) return false;
    if (stopFlag) return false;
    if (!await _retryStep('phrase4', () => AndroidImageMatcher.clickImage('phrase4', threshold: 0.3, delaySec: 0.3), logLine, logLineRed)) return false;
    if (stopFlag) return false;
    if (!await _retryStep('chain', () => AndroidImageMatcher.clickImage('chain', threshold: 0.3, delaySec: 0.3), logLine, logLineRed)) return false;
    await Future.delayed(const Duration(milliseconds: 500));
    return true;
  }

  /// 삭제 루프: first → wallet → delete → delete2 → 비밀번호. [count]회 반복
  static Future<void> _runDeleteLoop(void Function(String) logLine, int count) async {
    for (int i = 0; i < count && !stopFlag; i++) {
      logLine('→ 삭제 ${i + 1}/$count');
      if (!await AndroidImageMatcher.clickImage('first', threshold: 0.3, delaySec: 0.4)) continue;
      await Future.delayed(const Duration(milliseconds: 400));
      if (!await AndroidImageMatcher.clickImage('wallet', threshold: 0.3, delaySec: 0.35)) continue;
      await Future.delayed(const Duration(milliseconds: 400));
      if (!await AndroidImageMatcher.clickImage('delete', threshold: 0.3, delaySec: 0.35)) continue;
      await Future.delayed(const Duration(milliseconds: 400));
      if (!await AndroidImageMatcher.clickImage('delete2', threshold: 0.3, delaySec: 0.35)) continue;
      await Future.delayed(const Duration(milliseconds: 400));
      await _clickPasswordDigits(logLine);
      await Future.delayed(const Duration(milliseconds: 600));
    }
  }

  static Future<bool> _clickPasswordDigits(void Function(String) logLine) async {
    final pwd = password;
    if (pwd.isEmpty) return true;
    for (final char in pwd.split('')) {
      if (stopFlag) return false;
      final digit = int.tryParse(char);
      if (digit == null || digit < 0 || digit > 9) continue;
      final ok = await AndroidImageMatcher.clickImage('$digit', threshold: 0.3, delaySec: 0.03, waitScreenChange: false);
      if (!ok) return false;
      await Future.delayed(const Duration(milliseconds: 18));
    }
    return true;
  }

  static List<String>? _wordList; // 단어 목록 (한 줄에 한 단어)
  static String? _wordlistLoadError;
  static final Random _random = Random();

  /// 단어 목록(wordlist)에서 랜덤으로 12단어를 뽑아 문구 생성. 파일 없으면 BIP39 랜덤 생성.
  static Future<String?> _getNextPhrase() async {
    try {
      if (_wordList == null) {
        List<String> words = [];
        final base = (await getApplicationDocumentsDirectory()).path;
        final path = p.join(base, 'data', 'wordlist.txt');
        final file = File(path);
        if (file.existsSync()) {
          words = file
              .readAsLinesSync()
              .map((l) => l.trim())
              .where((l) => l.isNotEmpty && !l.startsWith('#'))
              .toList();
        } else {
          try {
            final text = await rootBundle.loadString('assets/data/wordlist.txt');
            words = text
                .split(RegExp(r'\r?\n'))
                .map((l) => l.trim())
                .where((l) => l.isNotEmpty && !l.startsWith('#'))
                .toList();
          } catch (_) {
            words = [];
          }
        }
        _wordList = words;
      }

      final words = _wordList!;
      if (words.length >= 12) {
        final phrase = List.generate(12, (_) => words[_random.nextInt(words.length)]).join(' ');
        return phrase;
      }

      // 단어가 12개 미만이면 BIP39 랜덤 12단어 사용
      return bip39.generateMnemonic();
    } catch (e) {
      _wordlistLoadError = '$e';
      try {
        return bip39.generateMnemonic();
      } catch (_) {
        return null;
      }
    }
  }

  /// wordlist 없을 때 원인 확인용 (로그에 찍기)
  static String? get wordlistLoadError => _wordlistLoadError;

  /// SafePal 삭제 루프만 테스트: first → select(오른쪽 탭) → delete1 → delete2 → 비밀번호 [count]회
  static Future<void> runSafePalDeleteTest({
    required void Function(String text) logLine,
    required void Function(String text) logLineRed,
    int count = 3,
  }) async {
    void dbLog(String s) => logLine(s);
    void dbLogRed(String s) => logLineRed(s);

    if (!Platform.isAndroid) {
      dbLogRed('이 앱은 Android에서만 동작합니다.');
      return;
    }

    stopFlag = false;
    AndroidImageMatcher.templateSubdir = 'app';
    AndroidImageMatcher.selectorOverrides = safePalSelectors;
    await AndroidImageMatcher.ensureAppTemplatesInDocuments();

    final hasTouch = await AndroidImageMatcher.hasTouchPermission();
    if (!hasTouch) {
      dbLogRed('접근성 권한이 필요합니다.');
      return;
    }

    await AndroidImageMatcher.acquireWakeLock();
    try {
      AndroidImageMatcher.debugLog = dbLog;
      final launched = await AppLauncher.launchSafePal();
      if (!launched) {
        dbLogRed('SafePal 앱을 찾을 수 없습니다.');
        return;
      }
      await Future.delayed(const Duration(milliseconds: 3000));

      const clickDelay = 0.2;
      for (int i = 0; i < count && !stopFlag; i++) {
        dbLog('--- 삭제 ${i + 1}/$count ---');
        if (!await _retryStep('first', () => AndroidImageMatcher.clickImage('first', threshold: 0.3, delaySec: clickDelay, waitScreenChange: false), dbLog, dbLogRed)) continue;
        await Future.delayed(const Duration(milliseconds: 200));
        if (!await AndroidImageMatcher.clickImageAtRight('select', threshold: 0.3, delaySec: clickDelay, waitScreenChange: false)) continue;
        await Future.delayed(const Duration(milliseconds: 200));
        if (!await AndroidImageMatcher.clickImage('delete1', threshold: 0.3, delaySec: clickDelay, waitScreenChange: false)) continue;
        await Future.delayed(const Duration(milliseconds: 200));
        if (!await AndroidImageMatcher.clickImage('delete2', threshold: 0.3, delaySec: clickDelay, waitScreenChange: false)) continue;
        await Future.delayed(const Duration(milliseconds: 200));
        await _clickPasswordDigits(dbLog);
        await Future.delayed(const Duration(milliseconds: 350));
      }
      dbLog('삭제 루프 테스트 완료');
    } finally {
      AndroidImageMatcher.debugLog = null;
      AndroidImageMatcher.templateSubdir = null;
      AndroidImageMatcher.selectorOverrides = null;
      await AndroidImageMatcher.releaseWakeLock();
    }
  }

  /// SafePal 클릭 패턴 수집용 테스트: runSafePal과 동일하지만 클릭 이벤트를 JSONL로 기록
  static Future<void> runSafePalRecordTest({
    required void Function(String text) logLine,
    required void Function(String text) logLineRed,
    required void Function(String phrase) onSuccessPhrase,
    required void Function(String text) replaceLogLastLine,
    required void Function(String text) setClipboard,
  }) async {
    stopFlag = false;
    _safePalClickProfiles.clear();
    AndroidImageMatcher.recordClicks = true;
    try {
      await runSafePal(
        logLine: logLine,
        logLineRed: logLineRed,
        onSuccessPhrase: onSuccessPhrase,
        replaceLogLastLine: replaceLogLastLine,
        setClipboard: setClipboard,
      );
    } finally {
      AndroidImageMatcher.recordClicks = false;
    }
  }

  static void requestStop() {
    stopFlag = true;
  }
}
