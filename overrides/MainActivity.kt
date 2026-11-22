package com.pulse.pulseaudio

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        createMediaNotificationChannel()
        handleWidgetIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.pulse.audio/widget"
        )
        PulseAudioWidgetProvider.attachChannel(channel)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "widgetReady" -> {
                    PulseAudioWidgetProvider.markDartReady()
                    result.success(null)
                }
                "updateWidget" -> {
                    val args = call.arguments as? Map<*, *>
                    if (args == null) {
                        result.error("INVALID_WIDGET_STATE", "Faltan datos del widget", null)
                    } else {
                        PulseAudioWidgetProvider.updateFromFlutter(this, args)
                        result.success(null)
                    }
                }
                "requestNotifications" -> {
                    requestNotificationPermission()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleWidgetIntent(intent)
    }

    override fun onDestroy() {
        PulseAudioWidgetProvider.detachChannel()
        super.onDestroy()
    }

    private fun handleWidgetIntent(intent: Intent?) {
        val command = when (intent?.action) {
            PulseAudioWidgetProvider.ACTION_TOGGLE_PLAYBACK -> "togglePlayback"
            PulseAudioWidgetProvider.ACTION_NEXT -> "next"
            PulseAudioWidgetProvider.ACTION_PREVIOUS -> "previous"
            PulseAudioWidgetProvider.ACTION_TOGGLE_SHUFFLE -> "toggleShuffle"
            else -> null
        } ?: return
        PulseAudioWidgetProvider.queueRemoteCommand(command)
        intent?.action = null
    }

    private fun createMediaNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            "com.pulse.audio",
            "PulseAudio",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            setShowBadge(false)
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
        }
    }
}
