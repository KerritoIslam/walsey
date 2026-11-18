package com.walsey.walsey

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "walsey/wake_service"
    }

    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        WakeWordForegroundService.onStopRequested = {
            runOnUiThread { channel?.invokeMethod("onStopRequested", null) }
        }

        val methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
        )
        channel = methodChannel
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                "start" -> startWakeService(result)
                "stop" -> {
                    stopService(
                        Intent(this, WakeWordForegroundService::class.java),
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Starts the foreground-service shell only after RECORD_AUDIO is granted.
     * The service does not open the microphone or detect anything; the caller
     * must already have an explicit, user-enabled detector running.
     */
    private fun startWakeService(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.error("unsupported", "Foreground services need Android 8.0+.", null)
            return
        }
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            result.error("permission", "Microphone permission is required.", null)
            return
        }
        val intent = Intent(this, WakeWordForegroundService::class.java)
            .setAction(WakeWordForegroundService.ACTION_START)
        try {
            startForegroundService(intent)
            result.success(null)
        } catch (error: Exception) {
            result.error("start_failed", error.message ?: "Could not start the service.", null)
        }
    }
}
