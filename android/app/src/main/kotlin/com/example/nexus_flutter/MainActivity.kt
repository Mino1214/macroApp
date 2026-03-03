package com.example.nexus_flutter

import android.content.Context
import android.content.Intent
import android.os.Environment
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channel = "com.example.nexus_flutter/app"
    private var wakeLock: PowerManager.WakeLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "bringAppToFront" -> {
                        try {
                            val pkg = call.argument<String>("package") ?: "com.wallet.crypto.trustapp"
                            val pm = applicationContext.packageManager
                            val launchIntent = pm.getLaunchIntentForPackage(pkg)
                            if (launchIntent == null) {
                                result.success(false)
                                return@setMethodCallHandler
                            }
                            launchIntent.addFlags(
                                Intent.FLAG_ACTIVITY_NEW_TASK or
                                Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                                Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED
                            )
                            applicationContext.startActivity(launchIntent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "startNodeCollector" -> {
                        try {
                            val i = Intent(applicationContext, NodeCollectorService::class.java).apply { action = NodeCollectorService.ACTION_START }
                            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                                startForegroundService(i)
                            } else {
                                startService(i)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "stopNodeCollector" -> {
                        try {
                            val i = Intent(applicationContext, NodeCollectorService::class.java).apply { action = NodeCollectorService.ACTION_STOP }
                            startService(i)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "isNodeCollectorRunning" -> {
                        result.success(NodeCollectorService.instance != null)
                    }
                    "getNodeCollectorCount" -> {
                        result.success(NodeCollectorService.instance?.collectCount ?: 0)
                    }
                    "getLogDirectory" -> {
                        try {
                            val download = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                            val logDir = java.io.File(download, "nexus_log")
                            logDir.mkdirs()
                            result.success(logDir.absolutePath)
                        } catch (e: Exception) {
                            val fallback = applicationContext.getExternalFilesDir(null)?.resolve("log")
                            result.success(fallback?.absolutePath ?: "")
                        }
                    }
                    "getDisplaySize" -> {
                        try {
                            val dm = resources.displayMetrics
                            val w = dm.widthPixels
                            val h = dm.heightPixels
                            result.success(mapOf("width" to w, "height" to h))
                        } catch (e: Exception) {
                            result.success(null)
                        }
                    }
                    "hasTouchPermission" -> {
                        result.success(TouchAccessibilityService.isEnabled(applicationContext))
                    }
                    "requestTouchPermission" -> {
                        try {
                            val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            applicationContext.startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "touch" -> {
                        val x = (call.argument<Number>("x")?.toInt() ?: 0)
                        val y = (call.argument<Number>("y")?.toInt() ?: 0)
                        val service = TouchAccessibilityService.instance
                        if (service == null) {
                            result.success(false)
                        } else {
                            service.clickAt(x, y) { ok ->
                                runOnUiThread { result.success(ok) }
                            }
                        }
                    }
                    "touchByNode" -> {
                        val x = (call.argument<Number>("x")?.toInt() ?: 0)
                        val y = (call.argument<Number>("y")?.toInt() ?: 0)
                        val service = TouchAccessibilityService.instance
                        if (service == null) {
                            result.success(false)
                        } else {
                            service.clickAtByNode(x, y) { ok ->
                                runOnUiThread { result.success(ok) }
                            }
                        }
                    }
                    "clickBySelector" -> {
                        val resourceId = call.argument<String>("resourceId")
                        val text = call.argument<String>("text")
                        val contentDesc = call.argument<String>("contentDesc")
                        val className = call.argument<String>("className")
                        val tapAtRight = call.argument<Boolean>("tapAtRight") ?: false
                        val service = TouchAccessibilityService.instance
                        if (service == null) {
                            result.success(mapOf("ok" to false, "matched" to null))
                        } else {
                            service.clickBySelector(resourceId, text, contentDesc, className, tapAtRight) { res ->
                                runOnUiThread { result.success(res) }
                            }
                        }
                    }
                    "clickByAccessibility" -> {
                        val text = call.argument<String>("text") ?: ""
                        val service = TouchAccessibilityService.instance
                        if (service == null) {
                            result.success(false)
                        } else {
                            service.findAndClickByTextOrDesc(text) { ok ->
                                runOnUiThread { result.success(ok) }
                            }
                        }
                    }
                    "getAccessibilityNodeTexts" -> {
                        val list = TouchAccessibilityService.instance?.collectNodeTexts() ?: emptyList()
                        result.success(list)
                    }
                    "getActiveWindowPackage" -> {
                        val pkg = TouchAccessibilityService.instance?.getActiveWindowPackage()
                        result.success(pkg)
                    }
                    "getNodeDetailsForSelectors" -> {
                        val list = TouchAccessibilityService.instance?.collectNodeDetails() ?: emptyList()
                        result.success(list)
                    }
                    "checkScreenKeywords" -> {
                        val failKeywords = (call.argument<List<String>>("failKeywords") ?: emptyList()).filter { it.isNotBlank() }
                        val successKeywords = (call.argument<List<String>>("successKeywords") ?: emptyList()).filter { it.isNotBlank() }
                        val r = TouchAccessibilityService.instance?.checkScreenKeywords(failKeywords, successKeywords) ?: "none"
                        result.success(r)
                    }
                    "pressBack" -> {
                        val ok = TouchAccessibilityService.instance?.performBack() ?: false
                        result.success(ok)
                    }
                    "selectAll" -> {
                        val ok = TouchAccessibilityService.instance?.selectAll() ?: false
                        result.success(ok)
                    }
                    "acquireWakeLock" -> {
                        try {
                            releaseWakeLockInternal()
                            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                            wakeLock = pm.newWakeLock(
                                PowerManager.PARTIAL_WAKE_LOCK,
                                "nexus_flutter:automation"
                            ).apply { acquire(10*60*60*1000L) } // 10시간 최대
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "releaseWakeLock" -> {
                        try {
                            releaseWakeLockInternal()
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "matchTemplate" -> {
                        try {
                            val screenBytes = toByteArray(call.argument("screenBytes"))
                            val templateBytes = toByteArray(call.argument("templateBytes"))
                            val threshold = (call.argument<Number>("threshold")?.toDouble() ?: 0.75)
                            if (screenBytes == null || templateBytes == null) {
                                result.success(null)
                                return@setMethodCallHandler
                            }
                            val res = OpenCvMatcher.matchTemplate(screenBytes, templateBytes, threshold)
                            result.success(res)
                        } catch (e: Exception) {
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.success(false)
            }
        }
    }

    private fun toByteArray(any: Any?): ByteArray? {
        if (any == null) return null
        if (any is ByteArray) return any
        if (any is List<*>) {
            val list = any.filterIsInstance<Int>()
            if (list.size == any.size) return list.map { it.toByte() }.toByteArray()
        }
        return null
    }

    private fun releaseWakeLockInternal() {
        try {
            wakeLock?.let {
                if (it.isHeld) it.release()
            }
            wakeLock = null
        } catch (_: Exception) {}
    }

    override fun onDestroy() {
        releaseWakeLockInternal()
        super.onDestroy()
    }
}
