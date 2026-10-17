package com.example.homework_companion

import android.app.PictureInPictureParams
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
