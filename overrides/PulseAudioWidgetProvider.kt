package com.pulse.pulseaudio

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.net.Uri
import android.os.SystemClock
import android.util.Base64
import android.view.View
import android.widget.RemoteViews
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.FileNotFoundException

class PulseAudioWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        refreshWidgets(context)
    }

    companion object {
        const val ACTION_TOGGLE_PLAYBACK = "com.pulse.pulseaudio.TOGGLE_PLAYBACK"
        const val ACTION_NEXT = "com.pulse.pulseaudio.NEXT"
        const val ACTION_PREVIOUS = "com.pulse.pulseaudio.PREVIOUS"
        const val ACTION_TOGGLE_SHUFFLE = "com.pulse.pulseaudio.TOGGLE_SHUFFLE"
        private const val PREFERENCES = "pulse_audio_widget"
        private const val ARTWORK_KEY = "artwork"
        private var methodChannel: MethodChannel? = null
        private var dartReady = false
        private val pendingCommands = mutableListOf<String>()
        private var cachedArtworkData: String? = null
        private var cachedArtwork: Bitmap? = null

        @Synchronized
        fun attachChannel(channel: MethodChannel) {
            methodChannel = channel
            dartReady = false
        }

        @Synchronized
        fun detachChannel() {
            methodChannel = null
            dartReady = false
        }

        @Synchronized
        fun markDartReady() {
            dartReady = true
            while (pendingCommands.isNotEmpty()) {
                methodChannel?.invokeMethod("remoteCommand", pendingCommands.removeAt(0))
            }
        }

        @Synchronized
        fun queueRemoteCommand(command: String) {
            pendingCommands.add(command)
            if (dartReady) markDartReady()
        }

        fun dispatchWidgetCommand(context: Context, action: String?) {
            val command = when (action) {
                ACTION_TOGGLE_PLAYBACK -> "togglePlayback"
                ACTION_NEXT -> "next"
                ACTION_PREVIOUS -> "previous"
                ACTION_TOGGLE_SHUFFLE -> "toggleShuffle"
                else -> return
            }
            requestCommand(context, command)
        }

        private fun requestCommand(context: Context, command: String) {
            val activeChannel = synchronized(this) {
                if (dartReady) methodChannel else null
            }
            if (activeChannel != null) {
                activeChannel.invokeMethod("remoteCommand", command)
                return
            }
            val action = when (command) {
                "togglePlayback" -> ACTION_TOGGLE_PLAYBACK
                "next" -> ACTION_NEXT
                "previous" -> ACTION_PREVIOUS
                else -> ACTION_TOGGLE_SHUFFLE
            }
            context.startActivity(
                Intent(context, MainActivity::class.java).apply {
                    this.action = action
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                }
            )
        }

        fun updateFromFlutter(context: Context, args: Map<*, *>) {
            val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            val editor = preferences.edit()
                .putBoolean("hasTrack", args["hasTrack"] as? Boolean ?: false)
                .putString("title", args["title"] as? String ?: "")
                .putString("artist", args["artist"] as? String ?: "")
                .putLong("durationMs", (args["durationMs"] as? Number)?.toLong() ?: 0L)
                .putLong("positionMs", (args["positionMs"] as? Number)?.toLong() ?: 0L)
                .putBoolean("playing", args["playing"] as? Boolean ?: false)
                .putBoolean("shuffle", args["shuffle"] as? Boolean ?: false)
            if (args["artworkChanged"] == true) {
                val artwork = (args["artwork"] as? ByteArray)
                    ?: readAlbumArtwork(context, args["albumId"] as? Number)
                if (artwork == null) {
                    editor.remove(ARTWORK_KEY)
                    cachedArtworkData = null
                    cachedArtwork = null
                } else {
                    val encoded = Base64.encodeToString(artwork, Base64.NO_WRAP)
                    editor.putString(ARTWORK_KEY, encoded)
                    cachedArtworkData = encoded
                    cachedArtwork = BitmapFactory.decodeByteArray(artwork, 0, artwork.size)
                }
            }
            editor.apply()
            refreshWidgets(context)
        }

        private fun refreshWidgets(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(
                ComponentName(context, PulseAudioWidgetProvider::class.java)
            )
            if (ids.isEmpty()) return

            val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            val views = RemoteViews(context.packageName, R.layout.pulseaudio_widget)
            val hasTrack = preferences.getBoolean("hasTrack", false)
            val playing = preferences.getBoolean("playing", false)
            val shuffle = preferences.getBoolean("shuffle", false)
            val duration = preferences.getLong("durationMs", 0L).coerceAtLeast(0L)
            val position = preferences.getLong("positionMs", 0L).coerceIn(0L, duration)

            views.setTextViewText(
                R.id.widget_title,
                preferences.getString("title", null).takeUnless { it.isNullOrBlank() }
                    ?: "PulseAudio"
            )
            views.setTextViewText(
                R.id.widget_artist,
                preferences.getString("artist", null).takeUnless { it.isNullOrBlank() }
                    ?: "Selecciona una canción"
            )
            views.setViewVisibility(
                R.id.widget_timing,
                if (hasTrack) View.VISIBLE else View.GONE
            )
            views.setViewVisibility(
                R.id.widget_progress,
                if (hasTrack) View.VISIBLE else View.GONE
            )
            views.setChronometer(
                R.id.widget_elapsed,
                SystemClock.elapsedRealtime() - position,
                "%s",
                hasTrack && playing
            )
            views.setTextViewText(R.id.widget_duration, formatTime(duration))
            val progress = if (duration == 0L) 0 else (position * 1000 / duration).toInt()
            views.setProgressBar(R.id.widget_progress, 1000, progress, false)
            views.setImageViewResource(
                R.id.widget_play_pause,
                if (playing) android.R.drawable.ic_media_pause
                else android.R.drawable.ic_media_play
            )
            views.setInt(
                R.id.widget_shuffle,
                "setColorFilter",
                if (shuffle) Color.rgb(29, 185, 84) else Color.WHITE
            )
            val artwork = loadArtwork(preferences.getString(ARTWORK_KEY, null))
            if (artwork == null) {
                views.setImageViewResource(R.id.widget_artwork, R.drawable.widget_music_note)
            } else {
                views.setImageViewBitmap(R.id.widget_artwork, artwork)
            }
            val openApp = PendingIntent.getActivity(
                context,
                0,
                Intent(context, MainActivity::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.widget_artwork, openApp)
            views.setOnClickPendingIntent(R.id.widget_title, openApp)
            views.setOnClickPendingIntent(
                R.id.widget_shuffle,
                commandIntent(context, 4, ACTION_TOGGLE_SHUFFLE)
            )
            views.setOnClickPendingIntent(
                R.id.widget_previous,
                commandIntent(context, 1, ACTION_PREVIOUS)
            )
            views.setOnClickPendingIntent(
                R.id.widget_play_pause,
                commandIntent(context, 2, ACTION_TOGGLE_PLAYBACK)
            )
            views.setOnClickPendingIntent(
                R.id.widget_next,
                commandIntent(context, 3, ACTION_NEXT)
            )
            manager.updateAppWidget(ids, views)
        }

        private fun commandIntent(
            context: Context,
            requestCode: Int,
            action: String
        ): PendingIntent = PendingIntent.getBroadcast(
            context,
            requestCode,
            Intent(context, PulseAudioWidgetActionReceiver::class.java).setAction(action),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        private fun loadArtwork(encoded: String?): Bitmap? {
            if (encoded == null) return null
            if (encoded != cachedArtworkData) {
                val bytes = Base64.decode(encoded, Base64.DEFAULT)
                cachedArtwork = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                cachedArtworkData = encoded
            }
            return cachedArtwork
        }

        private fun readAlbumArtwork(context: Context, albumId: Number?): ByteArray? {
            val id = albumId?.toLong() ?: return null
            if (id < 0) return null
            val uri = Uri.parse("content://media/external/audio/albumart/$id")
            val bitmap = try {
                context.contentResolver.openInputStream(uri)?.use {
                    BitmapFactory.decodeStream(it)
                }
            } catch (_: FileNotFoundException) {
                null
            } ?: return null
            return ByteArrayOutputStream().use { output ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, 85, output)
                output.toByteArray()
            }
        }

        class PulseAudioWidgetActionReceiver : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                PulseAudioWidgetProvider.dispatchWidgetCommand(context, intent.action)
            }
        }

        private fun formatTime(milliseconds: Long): String {
            val totalSeconds = milliseconds / 1000
            val seconds = (totalSeconds % 60).toString().padStart(2, '0')
            val minutes = (totalSeconds / 60) % 60
            val hours = totalSeconds / 3600
            return if (hours > 0) {
                "$hours:${minutes.toString().padStart(2, '0')}:$seconds"
            } else {
                "${totalSeconds / 60}:$seconds"
            }
        }

    }
}
