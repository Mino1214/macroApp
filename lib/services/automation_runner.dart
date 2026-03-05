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
      dbLog('화면캡처 권한 확인 (4초 대기)');
      await AndroidImageMatcher.requestScreenPermission();
      await Future.delayed(const Duration(seconds: 4));
      AndroidImageMatcher.debugLog = dbLog;
      final captureOk = await AndroidImageMatcher.testCapture();
      if (!captureOk) {
        dbLogRed('화면캡처 실패. 팝업에서 "시작" 눌렀는지 확인 후 다시 시도.');
        AndroidImageMatcher.debugLog = null;
        return;
      }
      dbLog('화면캡처 OK → SafePal 실행');
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

  static Future<void> _runSafePalFlow(
    void Function(String) logLine,
    void Function(String) logLineRed,
    void Function(String) onSuccessPhrase,
    void Function(String) setClipboard,
  ) async {
    int successCount = 0;
    String currentPhrase = '';
    int firstFailLoops = 0; // first 단계 연속 실패 루프 카운트

    // SafePal 속도 최적화: delaySec 0.18, 단계 간 80~220ms (기존보다 약간 빠르게)
    const clickDelay = 0.18;
    while (!stopFlag) {
      logLine('--- SafePal first (OpenCV) ---');
      if (!await _retryStep('first', () => AndroidImageMatcher.clickImage('first', threshold: 0.3, delaySec: clickDelay), logLine, logLineRed)) {
        firstFailLoops++;
        // first가 여러 번 연속으로 실패하면 무한 재시도 대신 강제로 중단해서 사용자가 상태를 확인할 수 있게 한다.
        if (firstFailLoops >= 5) {
          logLineRed('→ first 단계가 여러 번 연속으로 실패했습니다. SafePal 화면/해상도/템플릿(first.png)을 확인 후 다시 시작해주세요.');
          return;
        }
        await Future.delayed(const Duration(milliseconds: 260));
        continue;
      }
      // first가 한 번이라도 성공하면 카운터 리셋
      firstFailLoops = 0;
      await Future.delayed(const Duration(milliseconds: 200));

      logLine('--- second, third ---');
      if (!await _retryStep('second', () => AndroidImageMatcher.clickImage('second', threshold: 0.3, delaySec: clickDelay, waitScreenChange: false), logLine, logLineRed)) {
        await Future.delayed(const Duration(milliseconds: 260));
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

      if (successCount >= _safepalDeleteTarget) {
        logLine('--- delete loop $_safepalDeleteTarget회 ---');
        for (int i = 0; i < _safepalDeleteTarget && !stopFlag; i++) {
          logLine('→ 삭제 ${i + 1}/$_safepalDeleteTarget');
          if (!await _retryStep('first', () => AndroidImageMatcher.clickImage('first', threshold: 0.3, delaySec: clickDelay), logLine, logLineRed)) continue;
          await Future.delayed(const Duration(milliseconds: 180));
          if (!await AndroidImageMatcher.clickImageAtRight('select', threshold: 0.3, delaySec: clickDelay, waitScreenChange: false)) continue;
          await Future.delayed(const Duration(milliseconds: 180));
          if (!await AndroidImageMatcher.clickImage('delete1', threshold: 0.3, delaySec: clickDelay, waitScreenChange: false)) continue;
          await Future.delayed(const Duration(milliseconds: 180));
          if (!await AndroidImageMatcher.clickImage('delete2', threshold: 0.3, delaySec: clickDelay, waitScreenChange: false)) continue;
          await Future.delayed(const Duration(milliseconds: 180));
          await _clickPasswordDigits(logLine);
          await Future.delayed(const Duration(milliseconds: 320));
          successCount--;
        }
      }

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
      final ok = await AndroidImageMatcher.clickImage('$digit', threshold: 0.3, delaySec: 0.05, waitScreenChange: false);
      if (!ok) return false;
      await Future.delayed(const Duration(milliseconds: 35));
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
      dbLog('화면캡처 권한 확인');
      await AndroidImageMatcher.requestScreenPermission();
      await Future.delayed(const Duration(seconds: 2));
      AndroidImageMatcher.debugLog = dbLog;
      final captureOk = await AndroidImageMatcher.testCapture();
      if (!captureOk) {
        dbLogRed('화면캡처 실패.');
        return;
      }
      dbLog('SafePal 실행');
      final launched = await AppLauncher.launchSafePal();
      if (!launched) {
        dbLogRed('SafePal 앱을 찾을 수 없습니다.');
        return;
      }
      await Future.delayed(const Duration(milliseconds: 3000));

      const clickDelay = 0.2;
      for (int i = 0; i < count && !stopFlag; i++) {
        dbLog('--- 삭제 ${i + 1}/$count ---');
        if (!await _retryStep('first', () => AndroidImageMatcher.clickImage('first', threshold: 0.3, delaySec: clickDelay), dbLog, dbLogRed)) continue;
        await Future.delayed(const Duration(milliseconds: 200));
        if (!await AndroidImageMatcher.clickImageAtRight('select', threshold: 0.3, delaySec: clickDelay)) continue;
        await Future.delayed(const Duration(milliseconds: 200));
        if (!await AndroidImageMatcher.clickImage('delete1', threshold: 0.3, delaySec: clickDelay)) continue;
        await Future.delayed(const Duration(milliseconds: 200));
        if (!await AndroidImageMatcher.clickImage('delete2', threshold: 0.3, delaySec: clickDelay)) continue;
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

  static void requestStop() {
    stopFlag = true;
  }
}
