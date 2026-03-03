import 'dart:io';

import 'package:flutter/services.dart';

/// Trust Wallet / SafePal 앱 실행 - 자동으로 포그라운드로 전환
class AppLauncher {
  static const String trustWalletPackage = 'com.wallet.crypto.trustapp';
  static const String safePalPackage = 'io.safepal.wallet';
  static const _channel = MethodChannel('com.example.nexus_flutter/app');

  /// Trust Wallet 앱을 포그라운드로 전환 (실행 중이면 앞으로, 아니면 실행)
  static Future<bool> launchTrustWallet() async {
    if (!Platform.isAndroid) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('bringAppToFront', {'package': trustWalletPackage});
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// SafePal 앱을 포그라운드로 전환 (시드 스캔용)
  static Future<bool> launchSafePal() async {
    if (!Platform.isAndroid) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('bringAppToFront', {'package': safePalPackage});
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }
}

