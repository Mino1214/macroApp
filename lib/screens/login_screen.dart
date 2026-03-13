import 'package:flutter/material.dart';

import '../api/server_api.dart';
import '../theme/app_theme.dart';
import 'main_screen.dart';
import 'register_screen.dart';

/// 로그인(시작) 화면 - WinForms LoginForm과 동일 UI/동작
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _idController = TextEditingController();
  final _passwordController = TextEditingController();
  String _telegramText = '서버 로그인 · 텔레그램 문의: (불러오는 중)';
  String? _errorText;
  bool _errorVisible = false;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadTelegram();
  }

  Future<void> _loadTelegram() async {
    if (!ServerApi.enabled) return;
    final nick = await ServerApi.getTelegramNicknameAsync();
    if (!mounted) return;
    setState(() {
      _telegramText = nick == null || nick.isEmpty
          ? '서버 로그인 · 텔레그램 문의: (설정 안 됨)'
          : '서버 로그인 · 텔레그램 문의: $nick';
    });
  }

  Future<void> _onLogin() async {
    setState(() {
      _errorVisible = false;
      _errorText = null;
    });

    final id = _idController.text.trim();
    final pw = _passwordController.text.trim();

    if (id.isEmpty || pw.isEmpty) {
      setState(() {
        _errorText = '아이디와 비밀번호를 입력하세요.';
        _errorVisible = true;
      });
      return;
    }

    if (!ServerApi.enabled) {
      setState(() {
        _errorText = '서버에 연결할 수 없습니다.';
        _errorVisible = true;
      });
      return;
    }

    setState(() => _loading = true);
    final result = await ServerApi.loginAsync(id, pw);
    if (!mounted) return;
    setState(() => _loading = false);

    if (!result.ok || result.token == null) {
      setState(() {
        _errorText = '아이디 또는 비밀번호가 올바르지 않습니다.';
        _errorVisible = true;
      });
      return;
    }
    if (!ServerApi.isApproved()) {
      setState(() {
        _errorText = '승인 대기 중입니다. 관리자 승인 후 이용 가능합니다.';
        _errorVisible = true;
      });
      ServerApi.currentToken = null;
      ServerApi.currentUserId = null;
      return;
    }
    if (!ServerApi.isSubscriptionValid()) {
      setState(() {
        _errorText = '아이디 또는 비밀번호가 올바르지 않습니다.';
        _errorVisible = true;
      });
      ServerApi.currentToken = null;
      ServerApi.currentUserId = null;
      return;
    }

    ServerApi.currentToken = result.token;
    ServerApi.currentUserId = id;
    _openMain();
  }

  void _openMain() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const MainScreen()),
    );
  }

  void _openRegister() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RegisterScreen(telegramContact: _telegramText),
      ),
    );
  }

  @override
  void dispose() {
    _idController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgDark,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 32),
                  _buildBrand(),
                  const SizedBox(height: 24),
                  _buildLoginCard(context),
                  const SizedBox(height: 16),
                  _buildBottomInfo(),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBrand() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          decoration: BoxDecoration(
            color: AppTheme.accent.withOpacity(0.08),
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.all(10),
          child: Image.asset(
            'assets/data/app/logo.png',
            width: 32,
            height: 32,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) =>
                Icon(Icons.account_balance_wallet_rounded, size: 28, color: AppTheme.accent),
          ),
        ),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text(
              'Nexus',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: AppTheme.fg,
              ),
            ),
            SizedBox(height: 2),
            Text(
              '모바일 지갑 자동화',
              style: TextStyle(
                fontSize: 12,
                color: AppTheme.muted,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildLoginCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '로그인',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppTheme.fg,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Nexus 서버 계정으로 로그인해 주세요.',
              style: TextStyle(
                fontSize: 12,
                color: AppTheme.muted,
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _idController,
              decoration: const InputDecoration(
                labelText: '아이디',
                hintText: '아이디를 입력하세요',
              ),
              onSubmitted: (_) => _onLogin(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '비밀번호',
                hintText: '비밀번호를 입력하세요',
              ),
              onSubmitted: (_) => _onLogin(),
            ),
            if (_errorVisible && _errorText != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: AppTheme.logRed.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.error_outline, color: AppTheme.logRed, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _errorText!,
                        style: const TextStyle(color: AppTheme.logRed, fontSize: 13),
                        maxLines: 3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 18),
            ElevatedButton(
              onPressed: _loading ? null : _onLogin,
              child: Text(_loading ? '로그인 중...' : '로그인'),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: _openRegister,
              child: const Text('계정이 없으신가요? 회원가입'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomInfo() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _telegramText,
          style: const TextStyle(color: AppTheme.muted, fontSize: 11),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
        const Text(
          'v1.0.5',
          style: TextStyle(
            color: AppTheme.muted,
            fontSize: 10,
          ),
        ),
      ],
    );
  }
}
