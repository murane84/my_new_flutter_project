package com.ozilane.aluta

import android.app.NotificationManager
import android.os.Build
import com.ryanheise.audioservice.AudioServiceFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Extends AudioServiceFragmentActivity (which itself extends
// FlutterFragmentActivity) so BOTH plugins are satisfied at once:
//   • audio_service keeps receiving hardware media-button events
//     (car Bluetooth, steering wheel, headset), and
//   • local_auth can host the androidx BiometricPrompt, which requires the
//     host Activity to be a FragmentActivity.
class MainActivity : AudioServiceFragmentActivity() {
    // Lets Dart query real OS state that flutter_local_notifications cannot:
    // whether the app may currently show full-screen incoming-call intents
    // (the USE_FULL_SCREEN_INTENT grant, user-controllable on Android 14+).
    private val reliabilityChannel = "aluta/reliability"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            reliabilityChannel
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "canUseFullScreenIntent" -> result.success(canUseFullScreenIntent())
                else -> result.notImplemented()
            }
        }
    }

    private fun canUseFullScreenIntent(): Boolean {
        // Before Android 14 (UPSIDE_DOWN_CAKE) the permission is not gated —
        // full-screen intents are allowed by default.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return true
        val nm = getSystemService(NotificationManager::class.java)
        return nm?.canUseFullScreenIntent() ?: true
    }
}
