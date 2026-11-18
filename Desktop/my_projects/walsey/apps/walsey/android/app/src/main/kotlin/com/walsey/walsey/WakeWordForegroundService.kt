package com.walsey.walsey

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Foreground service shell for an opt-in wake-word detector.
 *
 * The service itself does NOT open the microphone and does NOT recognise
 * anything. It only keeps the process alive with the mandatory, visible
 * microphone-type notification while a detector (which must already be running
 * in Dart) is active. Starting it without a detector would be a fake
 * "listening" state, so the app never does that today.
 *
 * Rules encoded here:
 *  - `START_NOT_STICKY`: no automatic restart loop after the process dies.
 *  - The notification has a Stop action; stopping is always explicit.
 *  - The notification is not silent and cannot be dismissed while the service
 *    runs, matching Android's foreground-service contract.
 *  - No microphone permission is requested by the service; MainActivity checks
 *    it before starting.
 */
class WakeWordForegroundService : Service() {
    companion object {
        const val ACTION_START = "com.walsey.walsey.wake.START"
        const val ACTION_STOP = "com.walsey.walsey.wake.STOP"
        private const val CHANNEL_ID = "walsey_wake_listening"
        private const val NOTIFICATION_ID = 4310

        /** Invoked on the main thread when the user presses Stop. */
        @Volatile
        var onStopRequested: (() -> Unit)? = null
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        val notification = buildNotification()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (error: Exception) {
            // Android 14+ throws when the microphone FGS permission/type is
            // missing. Stop immediately instead of leaving a half-started
            // service behind.
            stopSelf()
            return START_NOT_STICKY
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        onStopRequested?.invoke()
        super.onDestroy()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Walsey voice",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Shown while the opt-in wake-word detector is active."
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this,
            1,
            Intent(this, WakeWordForegroundService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("Walsey is listening for its wake phrase")
            .setContentText("Hold-to-talk and typed input still work. Stop to end listening.")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentIntent(openApp)
            .addAction(
                Notification.Action.Builder(
                    null,
                    "Stop listening",
                    stop,
                ).build(),
            )
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
    }
}
