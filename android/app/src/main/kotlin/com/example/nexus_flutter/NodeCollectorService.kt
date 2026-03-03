package com.example.nexus_flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat

/**
 * 배경 노드 수집: Trust Wallet 등 포그라운드 앱의 접근성 노드를 5초마다 수집해 파일에 저장.
 */
class NodeCollectorService : Service() {

    private val handler = Handler(Looper.getMainLooper())
    private var isCollecting = false
    var collectCount = 0
        private set

    private val collectRunnable = object : Runnable {
        override fun run() {
            if (!isCollecting) return
            val service = TouchAccessibilityService.instance
            val list = service?.collectNodeDetails() ?: emptyList()
            if (!list.isEmpty()) {
                collectCount++
                updateNotification()
                try {
                    val dir = android.os.Environment.getExternalStoragePublicDirectory(
                        android.os.Environment.DIRECTORY_DOWNLOADS
                    ).resolve("nexus_log")
                    val fallback = getExternalFilesDir(null)?.resolve("log")
                    val targetDir = (dir.takeIf { it.canWrite() } ?: fallback) ?: return@run
                    targetDir.mkdirs()
                    val file = java.io.File(targetDir, "nodes_collected.txt")
                    val ts = java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.getDefault()).format(java.util.Date())
                    val header = "\n--- 수집 #$collectCount ($ts) ---\n"
                    file.appendText(header + list.joinToString("\n") + "\n", Charsets.UTF_8)
                } catch (_: Exception) {}
            }
            handler.postDelayed(this, 5000)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        createChannel()
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                isCollecting = true
                collectCount = 0
                startForeground(NOTIF_ID, buildNotification())
                handler.post(collectRunnable)
            }
            ACTION_STOP -> {
                isCollecting = false
                handler.removeCallbacks(collectRunnable)
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "노드 수집",
                NotificationManager.IMPORTANCE_LOW
            ).apply { setShowBadge(false) }
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val stopIntent = Intent(this, NodeCollectorService::class.java).apply { action = ACTION_STOP }
        val stopPending = PendingIntent.getService(
            this, 0, stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("노드 수집 중")
            .setContentText("Trust Wallet으로 전환 → 5초마다 자동 수집 (누적 ${collectCount}회)")
            .setSmallIcon(android.R.drawable.ic_menu_info_details)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "중지", stopPending)
            .setOngoing(true)
            .build()
    }

    fun updateNotification() {
        if (isCollecting) {
            try {
                getSystemService(NotificationManager::class.java).notify(NOTIF_ID, buildNotification())
            } catch (_: Exception) {}
        }
    }

    companion object {
        @Volatile
        var instance: NodeCollectorService? = null

        private const val CHANNEL_ID = "node_collector"
        private const val NOTIF_ID = 9001
        const val ACTION_START = "com.example.nexus_flutter.NODE_COLLECTOR_START"
        const val ACTION_STOP = "com.example.nexus_flutter.NODE_COLLECTOR_STOP"
    }
}
