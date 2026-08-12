package com.ozilane.aluta

import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import com.ryanheise.audioservice.AudioServiceFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

// Extends AudioServiceFragmentActivity (audio_service media buttons) which is a
// FlutterFragmentActivity (needed by local_auth's BiometricPrompt).
class MainActivity : AudioServiceFragmentActivity() {
    private val reliabilityChannel = "aluta/reliability"
    private val audioCaptureChannel = "aluta/audiocapture"

    // MediaProjection consent → internal audio capture ("identify song").
    private val reqCapture = 7331
    private var captureResult: MethodChannel.Result? = null
    private var captureDurationMs = 9000

    // OEM "Autostart" / "Auto-launch" screens. Component names differ per
    // manufacturer (and ROM version), so we try each until one resolves.
    private val autoStartComponents = listOf(
        ComponentName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity"),
        ComponentName("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity"),
        ComponentName("com.coloros.safecenter", "com.coloros.safecenter.startupapp.StartupAppListActivity"),
        ComponentName("com.oppo.safe", "com.oppo.safe.permission.startup.StartupAppListActivity"),
        ComponentName("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"),
        ComponentName("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity"),
        ComponentName("com.letv.android.letvsafe", "com.letv.android.letvsafe.AutobootManageActivity"),
        ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
        ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.optimize.process.ProtectActivity"),
        ComponentName("com.asus.mobilemanager", "com.asus.mobilemanager.entry.FunctionActivity"),
        ComponentName("com.transsion.phonemanager", "com.itel.autobootmanager.activity.AutoBootMgrActivity")
    )

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, reliabilityChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canUseFullScreenIntent" -> result.success(canUseFullScreenIntent())
                    "manufacturer" -> result.success(Build.MANUFACTURER ?: "")
                    "openAutostartSettings" -> result.success(openAutostart())
                    "openPopupPermissionSettings" -> result.success(openPopupPermission())
                    "openAppDetailsSettings" -> { openAppDetails(); result.success(true) }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, audioCaptureChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isSupported" ->
                        result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                    "capture" ->
                        startInternalCapture(call.argument<Int>("durationMs") ?: 9000, result)
                    else -> result.notImplemented()
                }
            }
    }

    // ── Internal audio capture ("identify song" → "from this phone") ─────────

    private fun startInternalCapture(durationMs: Int, result: MethodChannel.Result) {
        // Playback capture needs Android 10+.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.success(null)
            return
        }
        // One capture at a time.
        if (captureResult != null) {
            result.success(null)
            return
        }
        captureResult = result
        captureDurationMs = durationMs
        try {
            val mpm =
                getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            startActivityForResult(mpm.createScreenCaptureIntent(), reqCapture)
        } catch (e: Exception) {
            captureResult = null
            result.success(null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != reqCapture) return
        val res = captureResult
        captureResult = null
        if (res == null) return
        // Denied / cancelled.
        if (resultCode != RESULT_OK || data == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            res.success(null)
            return
        }
        val output = File(cacheDir, "aluta_cap_${System.currentTimeMillis()}.wav").absolutePath
        // The service reports the finished WAV path (or null) here.
        AudioCaptureService.onDone = { path -> runOnUiThread { res.success(path) } }
        val svc = Intent(this, AudioCaptureService::class.java).apply {
            putExtra(AudioCaptureService.EXTRA_CODE, resultCode)
            putExtra(AudioCaptureService.EXTRA_DATA, data)
            putExtra(AudioCaptureService.EXTRA_DURATION, captureDurationMs)
            putExtra(AudioCaptureService.EXTRA_OUTPUT, output)
        }
        try {
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(svc) else startService(svc)
        } catch (e: Exception) {
            AudioCaptureService.onDone = null
            res.success(null)
        }
    }

    private fun canUseFullScreenIntent(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return true
        val nm = getSystemService(NotificationManager::class.java)
        return nm?.canUseFullScreenIntent() ?: true
    }

    // Try each OEM Autostart screen; returns true if one opened, else falls
    // back to the app details page.
    private fun openAutostart(): Boolean {
        for (cn in autoStartComponents) {
            try {
                val intent = Intent().setComponent(cn).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                if (packageManager.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY) != null) {
                    startActivity(intent)
                    return true
                }
            } catch (_: Exception) {}
        }
        openAppDetails()
        return false
    }

    // MIUI "Other permissions" holds "Display pop-up windows while running in
    // the background". Elsewhere this falls back to the app details page.
    private fun openPopupPermission(): Boolean {
        try {
            val intent = Intent("miui.intent.action.APP_PERM_EDITOR").apply {
                setClassName("com.miui.securitycenter", "com.miui.permcenter.permissions.PermissionsEditorActivity")
                putExtra("extra_pkgname", packageName)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            if (packageManager.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY) != null) {
                startActivity(intent)
                return true
            }
        } catch (_: Exception) {}
        openAppDetails()
        return false
    }

    private fun openAppDetails() {
        try {
            val intent = Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:$packageName")
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
        } catch (_: Exception) {}
    }
}
