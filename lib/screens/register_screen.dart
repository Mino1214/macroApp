import 'package:flutter/material.dart';

import '../api/server_api.dart';
import '../theme/app_theme.dart';

/// 회원가입 - WinForms RegisterForm과 동일 UI/동작
class RegisterScreen extends StatefulWidget {
  final String telegramContact;

  const RegisterScreen({super.key, required this.telegramContact});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _idController = TextEditingController();
  final _passwordController = TextEditingController();
  final _referralController = TextEditingController();
  final _telegramController = TextEditingController();

  String _telegramText = '텔레그램 문의: (불러오는 중)';
  String? _errorText;
  bool _errorVisible = false;
  bool _success = false;

  @override
  void initState() {
    super.initState();
    _telegramText = widget.telegramContact;
    _loadTelegram();
  }

  Future<void> _loadTelegram() async {
    if (!ServerApi.enabled) return;
    final nick = await ServerApi.getTelegramNicknameAsync();
    if (!mounted) return;
    setState(() {
      _telegramText = nick == null || nick.isEmpty
          ? '텔레그램 문의: (설정 안 됨)'
          : '텔레그램 문의: $nick';
    });
  }

  Future<void> _onRegister() async {
    setState(() {
      _errorVisible = false;
      _errorText = null;
      _success = false;
    });

    final id = _idController.text.trim();
    final pw = _passwordController.text.trim();
    final referral = _referralController.text.trim();
    final telegram = _telegramController.text.trim();

    if (id.isEmpty || pw.isEmpty) {
      setState(() {
        _errorText = '아이디와 비밀번호를 입력하세요.';
        _errorVisible = true;
      });
      return;
    }
    if (referral.isEmpty) {
      setState(() {
        _errorText = '추천인 코드(매니저 아이디)를 입력하세요.';
        _errorVisible = true;
      });
      return;
    }

    final result = await ServerApi.registerAsync(
      id,
      pw,
      referral,
      telegram.isEmpty ? null : telegram,
    );
    if (!mounted) return;

    final message = result.message ?? (result.success ? '가입 요청이 완료되었습니다.' : '오류가 발생했습니다.');
    setState(() {
      _errorText = message;
      _errorVisible = true;
      _success = result.success;
      if (result.success) {
        _idController.clear();
        _passwordController.clear();
        _referralController.clear();
        _telegramController.clear();
      }
    });
  }

  @override
  void dispose() {
    _idController.dispose();
    _passwordController.dispose();
    _referralController.dispose();
    _telegramController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgDark,
      appBar: AppBar(
        title: const Text('회원가입'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Center(
        child: SingleChildScrollView(
          child: Container(
            width: 320,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppTheme.bgPanel,
              border: Border.all(color: Colors.grey.shade700),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '회원가입',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.accent,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                const _Label('아이디'),
                TextField(
                  controller: _idController,
                  decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
                  style: const TextStyle(color: AppTheme.fg),
                ),
                const _Label('비밀번호'),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
                  style: const TextStyle(color: AppTheme.fg),
                ),
                const _Label('추천인 코드'),
                TextField(
                  controller: _referralController,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    hintText: '예: qazwsx',
                  ),
                  style: const TextStyle(color: AppTheme.fg),
                ),
                const _Label('텔레그램 (선택)'),
                TextField(
                  controller: _telegramController,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    hintText: '@아이디',
                  ),
                  style: const TextStyle(color: AppTheme.fg),
                ),
                if (_errorVisible && _errorText != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _errorText!,
                    style: TextStyle(
                      color: _success ? AppTheme.accent : AppTheme.logRed,
                      fontSize: 13,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  height: 40,
                  child: ElevatedButton(
                    onPressed: _onRegister,
                    child: const Text('회원가입'),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 36,
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: TextButton.styleFrom(
                      backgroundColor: const Color(0xFF3C3C3F),
                      foregroundColor: AppTheme.fg,
                    ),
                    child: const Text('로그인으로 돌아가기'),
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

class _Label extends StatelessWidget {
  final String text;

  const _Label(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(text, style: const TextStyle(color: AppTheme.fg, fontSize: 14)),
      ),
    );
  }
}
