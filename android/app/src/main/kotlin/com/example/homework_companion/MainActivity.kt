package com.example.homework_companion

import android.app.PictureInPictureParams
import android.content.Intent
import android.content.res.Configuration
import android.os.Build
import android.util.Rational
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// Hosts Flutter and adds a small floating "mini player" (Picture-in-Picture):
/// the video keeps playing in a little window that can be dragged anywhere.
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var mediaChannel: MethodChannel? = null
    private var autoPip = false
    private var wide = true

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tubebox/pip")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "enter" -> {
                    wide = call.argument<Boolean>("wide") ?: true
                    result.success(enterPip())
                }
                "auto" -> {
                    autoPip = call.argument<Boolean>("on") ?: false
                    wide = call.argument<Boolean>("wide") ?: true
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // Background playback: media notification + service.
        val mc = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tubebox/media")
        mediaChannel = mc
        PlaybackService.onCommand = { cmd -> runOnUiThread { mc.invokeMethod("cmd", cmd) } }
        mc.setMethodCallHandler { call, result ->
            when (call.method) {
                "show" -> {
                    val t = call.argument<String>("title") ?: "TubeBox"
                    val sub = call.argument<String>("subtitle") ?: ""
                    val playing = call.argument<Boolean>("playing") ?: true
                    val prev = call.argument<Boolean>("prev") ?: false
                    val next = call.argument<Boolean>("next") ?: false
                    val art = call.argument<String>("art") ?: ""
                    val svc = PlaybackService.instance
                    if (svc != null) {
                        svc.update(t, sub, playing, prev, next, art)
                    } else {
                        val i = Intent(this, PlaybackService::class.java)
                            .putExtra("title", t).putExtra("subtitle", sub)
                            .putExtra("playing", playing).putExtra("prev", prev).putExtra("next", next).putExtra("art", art)
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(i) else startService(i)
                        } catch (e: Exception) {
                        }
                    }
                    result.success(true)
                }
                "progress" -> {
                    val pos = (call.argument<Number>("pos") ?: 0).toLong()
                    val dur = (call.argument<Number>("dur") ?: 0).toLong()
                    val playing = call.argument<Boolean>("playing") ?: true
                    PlaybackService.instance?.progress(pos, dur, playing)
                    result.success(true)
                }
                "quit" -> {
                    stopService(Intent(this, PlaybackService::class.java))
                    result.success(true)
                    finishAndRemoveTask()
                    window?.decorView?.postDelayed({ android.os.Process.killProcess(android.os.Process.myPid()) }, 400)
                }
                "stop" -> {
                    stopService(Intent(this, PlaybackService::class.java))
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun enterPip(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            val ratio = if (wide) Rational(16, 9) else Rational(9, 16)
            val params = PictureInPictureParams.Builder().setAspectRatio(ratio).build()
            enterPictureInPictureMode(params)
        } catch (e: Exception) {
            false
        }
    }

    // Pressing Home while a video plays shrinks it into the floating window.
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (autoPip) enterPip()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        channel?.invokeMethod("pip", isInPictureInPictureMode)
    }

    // Keep the web player alive (audio) while the app is in the background.
    // Android tells the WebView its window is hidden when the app stops, and
    // YouTube then silences the sound. Telling it "visible" again keeps it playing.
    private var stopped = false
    private val ticker = object : Runnable {
        override fun run() {
            if (!stopped) return
            wake(window?.decorView)
            window?.decorView?.postDelayed(this, 700)
        }
    }

    private fun wake(v: View?) {
        if (v is WebView) {
            v.onResume()
            v.resumeTimers()
            v.dispatchWindowVisibilityChanged(View.VISIBLE)
        } else if (v is ViewGroup) {
            for (i in 0 until v.childCount) wake(v.getChildAt(i))
        }
    }

    override fun onStop() {
        super.onStop()
        stopped = true
        window?.decorView?.post(ticker)
    }

    override fun onStart() {
        super.onStart()
        stopped = false
    }
}
