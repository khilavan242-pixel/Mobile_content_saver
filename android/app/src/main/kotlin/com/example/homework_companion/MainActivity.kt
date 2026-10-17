package com.example.homework_companion

import android.app.PictureInPictureParams
import android.content.Intent
import android.content.res.Configuration
import android.os.Build
import android.util.Rational
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
                    val svc = PlaybackService.instance
                    if (svc != null) {
                        svc.update(t, sub, playing, prev, next)
                    } else {
                        val i = Intent(this, PlaybackService::class.java)
                            .putExtra("title", t).putExtra("subtitle", sub)
                            .putExtra("playing", playing).putExtra("prev", prev).putExtra("next", next)
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(i) else startService(i)
                        } catch (e: Exception) {
                        }
                    }
                    result.success(true)
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
}
