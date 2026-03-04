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
        child: Container(
          width: 320,
          padding: const EdgeInsets.all(40),
          decoration: BoxDecoration(
            color: AppTheme.bgPanel,
            border: Border.all(color: Colors.grey.shade700),
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Image.asset(
                      'assets/data/app/logo.png',
                      width: 36,
                      height: 36,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => Icon(Icons.account_balance_wallet, size: 36, color: AppTheme.accent),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Nexus v1.0.2',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.accent,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('아이디', style: TextStyle(color: AppTheme.fg, fontSize: 14)),
                ),
                const SizedBox(height: 4),
                TextField(
                  controller: _idController,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  style: const TextStyle(color: AppTheme.fg, fontSize: 14),
                  onSubmitted: (_) => _onLogin(),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('비밀번호', style: TextStyle(color: AppTheme.fg, fontSize: 14)),
                ),
                const SizedBox(height: 4),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  style: const TextStyle(color: AppTheme.fg, fontSize: 14),
                  onSubmitted: (_) => _onLogin(),
                ),
                if (_errorVisible && _errorText != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _errorText!,
                    style: const TextStyle(color: AppTheme.logRed, fontSize: 13),
                    maxLines: 2,
                  ),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: ElevatedButton(
                    onPressed: _loading ? null : _onLogin,
                    child: Text(_loading ? '로그인 중...' : '로그인'),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _openRegister,
                  child: Text(
                    '계정이 없으신가요? 회원가입',
                    style: TextStyle(color: AppTheme.muted, fontSize: 14),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _telegramText,
                  style: TextStyle(color: AppTheme.muted, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
