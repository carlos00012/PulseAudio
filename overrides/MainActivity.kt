package com.pulse.pulseaudio

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private var notificationPermissionResult: MethodChannel.Result? = null

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
                    requestNotificationPermission(result)
                }
                "openNotificationSettings" -> {
                    openNotificationSettings()
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
        notificationPermissionResult?.error(
            "ACTIVITY_DESTROYED",
            "PulseAudio se cerró antes de completar el permiso",
            null
        )
        notificationPermissionResult = null
        PulseAudioWidgetProvider.detachChannel()
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != NOTIFICATION_PERMISSION_REQUEST) return
        val granted = grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
        notificationPermissionResult?.success(
            granted && getSystemService(NotificationManager::class.java).areNotificationsEnabled()
        )
        notificationPermissionResult = null
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
            PLAYBACK_CHANNEL_ID,
            "PulseAudio",
            NotificationManager.IMPORTANCE_DEFAULT
        ).apply {
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            setShowBadge(false)
            description = "Controles de reproducción"
            setSound(null, null)
            enableVibration(false)
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            if (notificationPermissionResult != null) {
                result.error("REQUEST_IN_PROGRESS", "Ya se está solicitando el permiso", null)
                return
            }
            notificationPermissionResult = result
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                NOTIFICATION_PERMISSION_REQUEST
            )
            return
        }
        result.success(
            getSystemService(NotificationManager::class.java).areNotificationsEnabled()
        )
    }

    private fun openNotificationSettings() {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                .putExtra(Settings.EXTRA_CHANNEL_ID, PLAYBACK_CHANNEL_ID)
        } else {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
        }
        startActivity(intent)
    }

    companion object {
        private const val PLAYBACK_CHANNEL_ID = "com.pulse.audio.playback.v2"
        private const val NOTIFICATION_PERMISSION_REQUEST = 1001
    }
}
