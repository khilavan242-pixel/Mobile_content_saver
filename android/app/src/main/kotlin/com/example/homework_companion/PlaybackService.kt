package com.example.homework_companion

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.net.URL

/// Foreground "media playback" service: keeps TubeBox alive in the background
/// and shows a media notification (lock screen + headset buttons too).
class PlaybackService : Service() {
    companion object {
        const val CHANNEL = "tubebox_playback"
        const val NOTIF_ID = 4711
        const val ACT_CMD = "tubebox.CMD"

        @Volatile var instance: PlaybackService? = null
        @Volatile var onCommand: ((String) -> Unit)? = null
    }

    private var session: MediaSession? = null
    private var wake: PowerManager.WakeLock? = null
    private var title = "TubeBox"
    private var subtitle = ""
    private var playing = true
    private var hasPrev = false
    private var hasNext = false
    private var started = false
    private var posMs = 0L
    private var durMs = 0L
    private var artUrl = ""
    @Volatile private var art: Bitmap? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        if (Build.VERSION.SDK_INT >= 26) {
            val ch = NotificationChannel(CHANNEL, "Playback", NotificationManager.IMPORTANCE_LOW)
            ch.setShowBadge(false)
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(ch)
        }
        val s = MediaSession(this, "TubeBox")
        s.setCallback(object : MediaSession.Callback() {
            override fun onPlay() { send("play") }
            override fun onPause() { send("pause") }
            override fun onSkipToNext() { send("next") }
            override fun onSkipToPrevious() { send("prev") }
            override fun onStop() { send("close") }
            override fun onSeekTo(pos: Long) { posMs = pos; send("seek:$pos") }
            override fun onCustomAction(action: String, extras: android.os.Bundle?) { if (action == "close") send("close") }
        })
        s.isActive = true
        session = s
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "TubeBox:playback").apply { acquire() }
        } catch (_: Exception) {
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACT_CMD) {
            send(intent.getStringExtra("cmd") ?: "")
            return START_NOT_STICKY
        }
        if (intent != null) {
            title = intent.getStringExtra("title") ?: title
            subtitle = intent.getStringExtra("subtitle") ?: subtitle
            playing = intent.getBooleanExtra("playing", playing)
            hasPrev = intent.getBooleanExtra("prev", hasPrev)
            hasNext = intent.getBooleanExtra("next", hasNext)
            val a = intent.getStringExtra("art") ?: ""
            if (a.isNotEmpty() && a != artUrl) update(title, subtitle, playing, hasPrev, hasNext, a)
        }
        refresh()
        return START_NOT_STICKY
    }

    fun update(t: String, s: String, p: Boolean, prev: Boolean, next: Boolean, artwork: String = "") {
        if (t != title) { posMs = 0L; durMs = 0L }
        if (artwork != artUrl) {
            artUrl = artwork
            art = null
            if (artwork.isNotEmpty()) {
                Thread {
                    try {
                        val bmp = BitmapFactory.decodeStream(URL(artwork).openStream())
                        if (bmp != null && artUrl == artwork) { art = bmp; refresh() }
                    } catch (_: Exception) {}
                }.start()
            }
        }
        title = t
        subtitle = s
        playing = p
        hasPrev = prev
        hasNext = next
        refresh()
    }

    /// Light update: only the timeline (position / length) and play state.
    fun progress(pos: Long, dur: Long, p: Boolean) {
        val durChanged = dur != durMs
        posMs = pos
        durMs = dur
        playing = p
        if (durChanged) pushMetadata()
        pushState()
    }

    private fun pushMetadata() {
        val s = session ?: return
        val mb = MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, title)
            .putString(MediaMetadata.METADATA_KEY_ARTIST, subtitle)
        if (durMs > 0) mb.putLong(MediaMetadata.METADATA_KEY_DURATION, durMs)
        art?.let { mb.putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, it) }
        s.setMetadata(mb.build())
    }

    private fun pushState() {
        val s = session ?: return
        val actions = PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_PLAY_PAUSE or
            PlaybackState.ACTION_SKIP_TO_NEXT or PlaybackState.ACTION_SKIP_TO_PREVIOUS or PlaybackState.ACTION_STOP or
            PlaybackState.ACTION_SEEK_TO
        s.setPlaybackState(
            PlaybackState.Builder()
                .setActions(actions)
                .addCustomAction(PlaybackState.CustomAction.Builder("close", "Close", android.R.drawable.ic_menu_close_clear_cancel).build())
                .setState(if (playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED, if (durMs > 0) posMs else PlaybackState.PLAYBACK_POSITION_UNKNOWN, 1f)
                .build()
        )
    }

    private fun send(cmd: String) {
        onCommand?.invoke(cmd)
    }

    private fun action(cmd: String, code: Int): PendingIntent {
        val i = Intent(this, PlaybackService::class.java).setAction(ACT_CMD).putExtra("cmd", cmd)
        return PendingIntent.getService(this, code, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    private fun refresh() {
        val s = session ?: return
        pushMetadata()
        pushState()

        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else Notification.Builder(this)
        b.setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(title)
            .setContentText(subtitle)
            .setContentIntent(open)
            .setLargeIcon(art)
            .setOngoing(playing)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .addAction(android.R.drawable.ic_media_previous, "Previous", action("prev", 1))
            .addAction(if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play, if (playing) "Pause" else "Play", action(if (playing) "pause" else "play", 2))
            .addAction(android.R.drawable.ic_media_next, "Next", action("next", 3))
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Close", action("close", 4))
            .setStyle(Notification.MediaStyle().setMediaSession(s.sessionToken).setShowActionsInCompactView(0, 1, 2))
        val n = b.build()
        if (!started) {
            started = true
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
            } else {
                startForeground(NOTIF_ID, n)
            }
        } else {
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIF_ID, n)
        }
    }

    override fun onDestroy() {
        instance = null
        try { session?.release() } catch (_: Exception) {}
        try { wake?.release() } catch (_: Exception) {}
        super.onDestroy()
    }
}
