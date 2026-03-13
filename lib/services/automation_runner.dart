import 'dart:io';
import 'dart:math';

import 'package:bip39_plus/bip39_plus.dart' as bip39;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'app_launcher.dart';
import 'android_image_matcher.dart';
import 'wallet_count_file.dart';

/// Trust Wallet (com.wallet.crypto.trustapp) 플로우
/// 템플릿: data/trustwallet — first, second, third, fourth, phrase1~4, chain,
///         wordinput, wordpaste, wordnext, fail, successPage, wallet, delete, delete2, 0~9
/// UIAutomator 선택자: 아래 맵에 넣으면 해당 스텝에서 이미지 대신 노드 클릭 먼저 시도 (first 이후 터치 차단 우회용)
class AutomationRunner {
  static bool stopFlag = false;
  static String password = '';

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

  /// SafePal (io.safepal.wallet) — first/errorword=OpenCV(assets/app), 나머지 desc 기반
  static final Map<String, Map<String, String?>> safePalSelectors = {
    'second': {'contentDesc': '지갑 추가', 'className': 'android.view.View'},
    'third': {'contentDesc': '기존 지갑 추가', 'className': 'android.widget.Button'},
    'paste': {'contentDesc': '불여넣기', 'className': 'android.widget.Button'},
    'next': {'contentDesc': '다음', 'className': 'android.widget.Button'},
    'confirm': {'contentDesc': '지금 가져오기', 'className': 'android.widget.Button'},
    'delete': {'contentDesc': '지우기', 'className': 'android.widget.Button'},
    'delete1': {'contentDesc': '지갑 삭제', 'className': 'android.widget.Button'},
    // 자산 홈에서 개별 지갑 행 선택용: Wallet01, Wallet02 ... 처럼 표시되는 뷰
    // 실제 클래스가 android.widget.ImageView인 경우도 있어서 className 조건은 빼고 desc만 사용.
    'select': {'contentDesc': 'Wallet'}, // ADDED: 클래스 제한 제거 → desc에 "Wallet" 포함이면 클릭
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
    AndroidImageMatcher.selectorOverrides = safePalSelectors;

    final hasTouch = await AndroidImageMatcher.hasTouchPermission();
    if (!hasTouch) {
      dbLogRed('접근성 권한이 필요합니다. 설정에서 Nexus를 활성화해주세요.');
      return;
    }

    await AndroidImageMatcher.acquireWakeLock();

    try {
      final launched = await AppLauncher.launchSafePal();
      if (!launched) {
        dbLogRed('SafePal 앱을 찾을 수 없습니다. (io.safepal.wallet)');
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
      AndroidImageMatcher.selectorOverrides = null;
      await AndroidImageMatcher.releaseWakeLock();
    }
  }


  // SafePal: 성공 니모닉 누적 개수 기준으로 삭제 루프 실행
  static const int _safepalDeleteTarget = 5; // ADDED: 10회마다 삭제

  static Future<void> _runSafePalFlow(
    void Function(String) logLine,
    void Function(String) logLineRed,
    void Function(String) onSuccessPhrase,
    void Function(String) setClipboard,
  ) async {
    int successCount = 0;
    String currentPhrase = '';

    // SafePal: 완전 노드(접근성) 기반으로만 동작하도록 first(OpenCV) 단계 제거.
    // SafePal 속도 최적화: delaySec 0.18, 단계 간 80~220ms (기존보다 약간 빠르게)
    const clickDelay = 0.18;
    while (!stopFlag) {
      logLine('--- SafePal select (Wallet 탭 진입) ---');
      // 자산 홈에서 Wallet01/Wallet02 탭으로 먼저 들어가야 "지갑 추가" 버튼이 노출됨.
      if (!await _retryStep(
        'select',
        () => AndroidImageMatcher.clickImageAtRight('select', threshold: 0.3, delaySec: clickDelay, waitScreenChange: false),
        logLine,
        logLineRed,
      )) {
        await Future.delayed(const Duration(milliseconds: 260));
        continue;
      }
      await Future.delayed(const Duration(milliseconds: 200));

      // select 후 온체인 영구 계약 화면에 진입했으면 즉시 뒤로가기
      if (await _escapeOnChainScreen(logLine)) continue;

      logLine('--- SafePal second, third ---');
      if (!await _retryStep('second', () => AndroidImageMatcher.clickImage('second', threshold: 0.3, delaySec: clickDelay, waitScreenChange: false), logLine, logLineRed)) {
        // 지갑 추가 버튼 미발견 → 온체인 영구 계약 등 잘못된 화면에 진입했을 수 있음
        // 앱 내 < 버튼 또는 pressBack×2로 한 단계 복귀 후 select부터 재시도
        logLine('⚠️ second 실패 → 뒤로가기 후 select 재시도');
        await _escapeOnChainScreen(logLine);
        await Future.delayed(const Duration(milliseconds: 300));
        continue;
      }
      if (stopFlag) break;
      if (!await _retryStep('third', () => AndroidImageMatcher.clickImage('third', threshold: 0.3, delaySec: clickDelay, waitScreenChange: false), logLine, logLineRed)) {
        await Future.delayed(const Duration(milliseconds: 260));
        continue;
      }
      await Future.delayed(const Duration(milliseconds: 200));

      if (password.isNotEmpty) {
        logLine('--- 비밀번호 ---');
        if (!await _clickPasswordDigits(logLine)) {
          logLineRed('→ 비밀번호 ✗');
          await Future.delayed(const Duration(milliseconds: 260));
          continue;
        }
        await Future.delayed(const Duration(milliseconds: 150));
      }

      // [12생성 & 기억]
      currentPhrase = (await _getNextPhrase()) ?? '';
      if (currentPhrase.isEmpty) {
        logLine('wordlist 없음');
        return;
      }
      setClipboard(currentPhrase);
      await Future.delayed(const Duration(milliseconds: 80));

      logLine('--- 니모닉 첫 1회: paste, next, confirm ---');
      if (!await _retryStep('paste', () => AndroidImageMatcher.clickImage('paste', threshold: 0.3, delaySec: clickDelay, waitScreenChange: false), logLine, logLineRed)) {
        await Future.delayed(const Duration(milliseconds: 260));
        continue;
      }
      await Future.delayed(const Duration(milliseconds: 80));
      if (stopFlag) break;
      if (!await _retryStep('next', () => AndroidImageMatcher.clickImage('next', threshold: 0.3, delaySec: clickDelay, waitScreenChange: false), logLine, logLineRed)) {
        await Future.delayed(const Duration(milliseconds: 260));
        continue;
      }
      await Future.delayed(const Duration(milliseconds: 80));
      if (stopFlag) break;
      if (!await _retryStep('confirm', () => AndroidImageMatcher.clickImage('confirm', threshold: 0.3, delaySec: clickDelay, waitScreenChange: false), logLine, logLineRed)) {
        await Future.delayed(const Duration(milliseconds: 260));
        continue;
      }
      await Future.delayed(const Duration(milliseconds: 550)); // confirm 후 화면 안정화

      const int maxWaitAttempts = 50; // 약 15초 후 타임아웃
      int waitAttempts = 0;
      const failKeywords = ['지우기', '지갑 가져오기', '클라우드', '내 클라우드'];
      // SafePal 자산 첫 화면 전용 키워드: '가스 스테이션'만 사용 (가장 고유함)
      const gasStationKeywords = ['가스 스테이션'];
      while (!stopFlag) {
        await Future.delayed(const Duration(milliseconds: 260));
        // 성공/실패를 분리해서 판정:
        // 1) 성공 키워드만 먼저 검사:
        //    '가스 스테이션'이 보이면 SafePal 자산 홈 화면으로 간주 → 성공
        final gasResult = await AndroidImageMatcher.checkScreenKeywords(
          failKeywords: const [],
          successKeywords: gasStationKeywords,
        );
        final hasGasStation = gasResult == 'success';

        if (hasGasStation) {
          logLine('→ success (SafePal 자산 화면 판정: gasStation=$hasGasStation)');
          onSuccessPhrase(currentPhrase);
          successCount++;
          logLine('→ successCount=$successCount (SafePal 성공 누적)');

          // ADDED: SafePal - 성공 10회마다 지갑 삭제 루프 실행
          if (successCount >= _safepalDeleteTarget) {
            logLine('→ SafePal 성공이 $_safepalDeleteTarget회 누적됨 → 삭제 루프(1회) 실행');
            // ADDED: 디버깅 및 안정성을 위해 한 번만 삭제 시도
            await _runSafePalDeleteLoop(logLine, logLineRed, count: 5);
            successCount = 0;
          }

          break;
        }

        // 2) 성공이 아니라면, 이번에는 실패 키워드만 검사해서 fail 여부 판정
        final failOnly = await AndroidImageMatcher.checkScreenKeywords(
          failKeywords: failKeywords,
          successKeywords: const [],
        );
        if (failOnly == 'fail') {
          logLine('→ fail → 재귀 (새 문구 시도)');
          if (!await AndroidImageMatcher.clickImage('delete', threshold: 0.3, delaySec: clickDelay, waitScreenChange: false)) break;
          await Future.delayed(const Duration(milliseconds: 80));
          if (!await AndroidImageMatcher.clickImage('paste', threshold: 0.3, delaySec: clickDelay, waitScreenChange: false)) break;
          await Future.delayed(const Duration(milliseconds: 80));
          // [12생성 & 기억] — 새 문구
          final nextPhrase = await _getNextPhrase();
          if (nextPhrase == null || nextPhrase.isEmpty) break;
          currentPhrase = nextPhrase;
          setClipboard(currentPhrase);
          await Future.delayed(const Duration(milliseconds: 40));
          if (!await AndroidImageMatcher.clickImage('next', threshold: 0.3, delaySec: clickDelay, waitScreenChange: false)) break;
          await Future.delayed(const Duration(milliseconds: 80));
          if (!await AndroidImageMatcher.clickImage('confirm', threshold: 0.3, delaySec: clickDelay, waitScreenChange: false)) break;
          await Future.delayed(const Duration(milliseconds: 360));
          continue;
        }

        waitAttempts++;
        final pkg = await AndroidImageMatcher.getActiveWindowPackage();
        logLine('→ 화면 대기 (SafePal 성공/실패 판정) gas=$hasGasStation fail=$failOnly pkg=$pkg $waitAttempts/$maxWaitAttempts');
        if (waitAttempts >= maxWaitAttempts) {
          logLineRed('→ 화면 판정 타임아웃 → first부터 재시도');
          break;
        }
        await Future.delayed(const Duration(milliseconds: 220));
      }

      // SafePal: 자동 삭제 루프는 노드/앱 버전에 따라 불안정할 수 있어 비활성화.
      await Future.delayed(const Duration(milliseconds: 220));
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

        // 온체인 영구 계약 화면 탈출: 잘못 진입했을 경우 뒤로가기 후 외부 루프 재시작
        if (await _escapeOnChainScreen(logLine)) break;

        if (firstTimeInLoop) {
          logLine('--- 니모닉 입력 (최초 1회) ---');
          final phrase = await _getNextPhrase();
          if (phrase == null || phrase.isEmpty) {
            logLine('wordlist 없음${AutomationRunner.wordlistLoadError != null ? " — ${AutomationRunner.wordlistLoadError}" : ""}');
            return;
          }
          setClipboard(phrase);
          addAttemptedPhrase(phrase);
          await Future.delayed(const Duration(milliseconds: 80));

          if (!await AndroidImageMatcher.clickImage('wordinput', threshold: 0.3, delaySec: 0.3)) {
            logLineRed('→ wordinput ✗');
            break;
          }
          await Future.delayed(const Duration(milliseconds: 180));
          if (!await AndroidImageMatcher.clickImage('wordpaste', threshold: 0.3, delaySec: 0.3)) {
            logLineRed('→ wordpaste ✗');
            break;
          }
          await Future.delayed(const Duration(milliseconds: 180));
          if (!await AndroidImageMatcher.clickImage('wordnext', threshold: 0.3, delaySec: 0.3)) {
            logLineRed('→ wordnext ✗');
            break;
          }
          firstTimeInLoop = false;
          await Future.delayed(const Duration(milliseconds: 520));
          continue;
        }

        await Future.delayed(const Duration(milliseconds: 400));
        logLine('→ fail 확인 중...');
        final failFound = await AndroidImageMatcher.findImage('fail', threshold: 0.3);
        if (failFound != null) {
          logLine('→ fail ✓ (새 니모닉 시도)');
          await AndroidImageMatcher.selectAll();
          await Future.delayed(const Duration(milliseconds: 120));
          final phrase = await _getNextPhrase();
          if (phrase == null || phrase.isEmpty) break;
          setClipboard(phrase);
          addAttemptedPhrase(phrase);
          await Future.delayed(const Duration(milliseconds: 80));
          if (!await AndroidImageMatcher.clickImage('wordpaste', threshold: 0.3, delaySec: 0.3)) break;
          await Future.delayed(const Duration(milliseconds: 180));
          if (!await AndroidImageMatcher.clickImage('wordnext', threshold: 0.3, delaySec: 0.3)) break;
          await Future.delayed(const Duration(milliseconds: 520));
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

  static Future<bool> _retryStep(String name, Future<bool> Function() tap, void Function(String) logLine, void Function(String) logLineRed) async {
    for (var i = 0; i < _maxStepRetries && !stopFlag; i++) {
      if (await tap()) return true;
      logLineRed('→ $name ✗ (${i + 1}/$_maxStepRetries 재시도)');
      await Future.delayed(const Duration(milliseconds: 250));
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
  /// 중간 단계 실패 시 pressBack()으로 초기 화면 복귀 후 재시도 — 화면 상태 불일치로 인한 루프 정지 방지
  static Future<void> _runDeleteLoop(void Function(String) logLine, int count) async {
    for (int i = 0; i < count && !stopFlag; i++) {
      logLine('→ 삭제 ${i + 1}/$count');
      if (!await AndroidImageMatcher.clickImage('first', threshold: 0.3, delaySec: 0.4)) continue;
      await Future.delayed(const Duration(milliseconds: 400));

      if (!await AndroidImageMatcher.clickImage('wallet', threshold: 0.3, delaySec: 0.35)) {
        // first 클릭 후 다른 화면으로 이동했으므로 뒤로가기로 복귀
        await AndroidImageMatcher.pressBack();
        await Future.delayed(const Duration(milliseconds: 500));
        continue;
      }
      await Future.delayed(const Duration(milliseconds: 400));

      if (!await AndroidImageMatcher.clickImage('delete', threshold: 0.3, delaySec: 0.35)) {
        // wallet 상세 화면에서 뒤로가기 × 2 로 복귀
        await AndroidImageMatcher.pressBack();
        await Future.delayed(const Duration(milliseconds: 300));
        await AndroidImageMatcher.pressBack();
        await Future.delayed(const Duration(milliseconds: 500));
        continue;
      }
      await Future.delayed(const Duration(milliseconds: 400));

      if (!await AndroidImageMatcher.clickImage('delete2', threshold: 0.3, delaySec: 0.35)) {
        // 다이얼로그/삭제확인 화면에서 뒤로가기 × 2 로 복귀
        await AndroidImageMatcher.pressBack();
        await Future.delayed(const Duration(milliseconds: 300));
        await AndroidImageMatcher.pressBack();
        await Future.delayed(const Duration(milliseconds: 500));
        continue;
      }
      await Future.delayed(const Duration(milliseconds: 400));
      await _clickPasswordDigits(logLine);
      // 삭제 완료 후 UI가 완전히 안정화될 때까지 충분히 대기
      await Future.delayed(const Duration(milliseconds: 900));
    }
  }

  static Future<bool> _clickPasswordDigits(void Function(String) logLine) async {
    final pwd = password;
    if (pwd.isEmpty) return true;
    for (final char in pwd.split('')) {
      if (stopFlag) return false;
      final digit = int.tryParse(char);
      if (digit == null || digit < 0 || digit > 9) continue;
      final ok = await AndroidImageMatcher.clickImage('$digit', threshold: 0.3, delaySec: 0.05, waitScreenChange: false);
      if (!ok) return false;
      await Future.delayed(const Duration(milliseconds: 35));
    }
    return true;
  }

  /// SafePal: 자산 화면에서 개별 지갑을 선택해 삭제하는 루프 (노드 기반).
  /// 앱 버전·UI에 따라 실패할 수 있으므로, 실패해도 전체 플로우는 계속 진행한다.
  static Future<void> _runSafePalDeleteLoop(
    void Function(String) logLine,
    void Function(String) logLineRed, {
    required int count,
  }) async {
    for (int i = 0; i < count && !stopFlag; i++) {
      int attempt = 0;
      bool deleted = false;
      while (attempt < 3 && !stopFlag && !deleted) {
        attempt++;
        logLine('→ SafePal 삭제 ${i + 1}/$count (시도 $attempt/3)');

        // 1) 자산 화면에서 지갑 행 오른쪽 탭 → 하단 시트(스크림) 열기
        final selected = await AndroidImageMatcher.clickImageAtRight(
          'select',
          threshold: 0.3,
          delaySec: 0.3,
          waitScreenChange: false,
        );
        if (!selected) {
          logLineRed('→ SafePal 삭제: select ✗');
          await Future.delayed(const Duration(milliseconds: 400));
          continue;
        }
        // 하단 시트 애니메이션 완료 대기
        await Future.delayed(const Duration(milliseconds: 700));

        // 1-2) 열린 화면(하단 시트)에서 지갑 항목 오른쪽 다시 탭 → 삭제 옵션 진입
        // select 후 스크림이 올라오면서 지갑 목록이 보이는데, 그 중 하나를 우측 탭해야 지갑 삭제 버튼 노출
        final selected2 = await AndroidImageMatcher.clickImageAtRight(
          'select',
          threshold: 0.3,
          delaySec: 0.3,
          waitScreenChange: false,
        );
        if (!selected2) {
          logLineRed('→ SafePal 삭제: select2 ✗');
          await AndroidImageMatcher.pressBack();
          await Future.delayed(const Duration(milliseconds: 500));
          continue;
        }
        // 삭제 옵션 화면 전환 완료 대기
        await Future.delayed(const Duration(milliseconds: 700));

        // 2) "지갑 삭제" 버튼 (여러 방식으로 강하게 재시도)
        final delete1 = await _clickSafePalDeleteButton(logLine, logLineRed);
        if (!delete1) {
          logLineRed('→ SafePal 삭제: delete1 ✗');
          await AndroidImageMatcher.pressBack();
          await Future.delayed(const Duration(milliseconds: 300));
          await AndroidImageMatcher.pressBack();
          await Future.delayed(const Duration(milliseconds: 500));
          continue;
        }
        await Future.delayed(const Duration(milliseconds: 400));

        // 3) 확인 다이얼로그의 "삭제"
        final delete2 = await _clickSafePalDeleteConfirm(logLine, logLineRed);
        if (!delete2) {
          logLineRed('→ SafePal 삭제: delete2 ✗');
          // 다이얼로그 닫고 상세화면도 뒤로가기
          await AndroidImageMatcher.pressBack();
          await Future.delayed(const Duration(milliseconds: 300));
          await AndroidImageMatcher.pressBack();
          await Future.delayed(const Duration(milliseconds: 500));
          continue;
        }
        await Future.delayed(const Duration(milliseconds: 400));

        // 4) PIN 비밀번호가 있다면 숫자 패드로 입력
        final okPwd = await _clickPasswordDigits(logLine);
        if (!okPwd) {
          logLineRed('→ SafePal 삭제: 비밀번호 입력 ✗');
          await AndroidImageMatcher.pressBack();
          await Future.delayed(const Duration(milliseconds: 300));
          await AndroidImageMatcher.pressBack();
          await Future.delayed(const Duration(milliseconds: 500));
          continue;
        }
        // 삭제 완료 후 UI 안정화 대기
        await Future.delayed(const Duration(milliseconds: 900));
        deleted = true;
      }
    }
  }
  /// SafePal 삭제 다이얼로그 확인 버튼/메시지 클릭:
  /// 1차: desc "삭제" + class android.widget.Button (실제 버튼)
  /// 2차: desc "삭제하시겠습니까" (메시지 뷰를 탭)
  static Future<bool> _clickSafePalDeleteConfirm(
    void Function(String) logLine,
    void Function(String) logLineRed,
  ) async {
    // 1) 버튼 자체 시도: desc="삭제" 인 버튼
    final (okBtn, matchedBtn, screenNodes1) = await AndroidImageMatcher.clickBySelector(
      resourceId: null,
      text: null,
      contentDesc: '삭제',
      className: 'android.widget.Button',
      tapAtRight: false,
    );
    if (okBtn) {
      return true;
    }
    if (screenNodes1 != null && screenNodes1.isNotEmpty) {
      logLineRed('→ SafePal 삭제: delete2 버튼 ✗ (nodes: $screenNodes1)');
    }

    // 2) 메시지 뷰 시도: desc에 "삭제하시겠습니까"가 포함된 노드
    final (okMsg, matchedMsg, screenNodes2) = await AndroidImageMatcher.clickBySelector(
      resourceId: null,
      text: null,
      contentDesc: '삭제하시겠습니까',
      className: null,
      tapAtRight: false,
    );
    if (!okMsg && screenNodes2 != null && screenNodes2.isNotEmpty) {
      logLineRed('→ SafePal 삭제: delete2 메시지 ✗ (nodes: $screenNodes2)');
    }
    return okMsg;
  }

  /// SafePal 지갑 상세/옵션 화면에서 "지갑 삭제" 버튼을 최대 3번까지 여러 방식으로 시도.
  static Future<bool> _clickSafePalDeleteButton(
    void Function(String) logLine,
    void Function(String) logLineRed,
  ) async {
    for (var attempt = 1; attempt <= 3; attempt++) {
      // 1) className 제한 없이 desc만으로 탐색 (SafePal은 android.view.View로 버튼 구현)
      final (okView, _, _) = await AndroidImageMatcher.clickBySelector(
        resourceId: null,
        text: null,
        contentDesc: '지갑 삭제',
        className: null,
        tapAtRight: false,
      );
      if (okView) return true;

      // 2) android.widget.Button 클래스 한정으로도 시도 (버전에 따라 달라질 수 있음)
      final (okBtn, _, _) = await AndroidImageMatcher.clickBySelector(
        resourceId: null,
        text: null,
        contentDesc: '지갑 삭제',
        className: 'android.widget.Button',
        tapAtRight: false,
      );
      if (okBtn) return true;

      // 3) 접근성 텍스트 전체 트리 탐색 폴백
      final okText = await AndroidImageMatcher.clickByAccessibilityText('지갑 삭제');
      if (okText) return true;

      await Future.delayed(const Duration(milliseconds: 300));
    }
    return false;
  }

  static List<String>? _wordList; // 단어 목록 (한 줄에 한 단어)
  static String? _wordlistLoadError;
  static final Random _random = Random();


  /// BIP39 라이브러리로만 12단어 니모닉을 생성 (wordlist 파일 사용 안 함).
  static Future<String?> _getNextPhrase() async {
    try {
      return bip39.generateMnemonic(); // ADDED: 항상 BIP39 유효 니모닉 생성
    } catch (e) {
      _wordlistLoadError = '$e';
      return null;
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
    // 노드 기반 버전에서는 캡처/이미지 매칭을 쓰지 않으므로,
    // SafePal 삭제 테스트는 일단 비활성화해 둔다.
    logLine('SafePal 삭제 루프 테스트는 노드 기반 버전에서는 비활성화되어 있습니다.');
  }

  /// "온체인 영구 계약" 오류 화면 감지 → back.png 이미지 매칭으로 < 버튼 클릭
  /// 해당 화면이 아니면 false 반환
  static Future<bool> _escapeOnChainScreen(void Function(String) logLine) async {
    try {
      // checkScreenKeywords는 내부에서 ZWJ를 normalizeForMatch로 제거 후 비교하므로
      // getAccessibilityNodeTexts()의 raw 문자열 ZWJ 문제를 우회할 수 있음
      // 'Perpetuals'(ASCII)를 병행 검사해 ZWJ 혼재 환경에서도 안정적으로 감지
      final result = await AndroidImageMatcher.checkScreenKeywords(
        failKeywords: const ['온체인 영구 계약', 'Perpetuals'],
        successKeywords: const [],
      );
      if (result != 'fail') return false;

      logLine('⚠️ 온체인 영구 계약 화면 감지 → back.png 이미지 매칭으로 탈출 시도');

      // back.png는 assets/data/app/ 에 있으므로 templateSubdir를 임시로 'app'으로 전환
      final prevSubdir = AndroidImageMatcher.templateSubdir;
      AndroidImageMatcher.templateSubdir = 'app';
      try {
        // selectorOverrides에 'back' 키가 없으므로 바로 OpenCV 이미지 매칭 사용
        final clicked = await AndroidImageMatcher.clickImage(
          'back',
          threshold: 0.6,
          delaySec: 0.3,
          waitScreenChange: false,
        );
        if (clicked) {
          logLine('⚠️ back.png 클릭 성공 → 루프 재시작');
          await Future.delayed(const Duration(milliseconds: 500));
          return true;
        }
        logLine('⚠️ back.png 미발견 → pressBack×2 폴백');
      } finally {
        AndroidImageMatcher.templateSubdir = prevSubdir;
      }

      // 이미지 매칭 실패 시 pressBack 2번 (1차=키보드닫기, 2차=화면이동)
      await AndroidImageMatcher.pressBack();
      await Future.delayed(const Duration(milliseconds: 350));
      await AndroidImageMatcher.pressBack();
      await Future.delayed(const Duration(milliseconds: 500));
      return true;
    } catch (_) {}
    return false;
  }

  static void requestStop() {
    stopFlag = true;
  }
}
