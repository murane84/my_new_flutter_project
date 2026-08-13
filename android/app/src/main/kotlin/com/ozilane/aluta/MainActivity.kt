package com.ozilane.aluta

import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.telecom.CallAudioState
import android.telecom.DisconnectCause
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import com.ryanheise.audioservice.AudioServiceFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

// Extends AudioServiceFragmentActivity (audio_service media buttons) which is a
// FlutterFragmentActivity (needed by local_auth's BiometricPrompt).
class MainActivity : AudioServiceFragmentActivity() {
    private val reliabilityChannel = "aluta/reliability"
    private val audioCaptureChannel = "aluta/audiocapture"
    private val telecomChannel = "aluta/telecom"
    private val connectedContactsChannel = "aluta/connected_contacts"

    // Channel for the "Connected apps" (ContactsContract) integration, plus a
    // stash for an action tapped from the system Contacts app before Dart is
    // listening (cold start) — consumed via "consumePendingAction".
    private var contactsMc: MethodChannel? = null
    private var pendingContactAction: HashMap<String, String>? = null

    // MediaProjection consent → internal audio capture ("identify song").
    private val reqCapture = 7331
    private var captureResult: MethodChannel.Result? = null
    private var captureDurationMs = 9000

    // Channel for pushing telecom events (car/BT answer/end) up to Dart.
    private var telecomMc: MethodChannel? = null

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

        val tmc = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, telecomChannel)
        telecomMc = tmc
        tmc.setMethodCallHandler { call, result -> handleTelecom(call, result) }
        // Forward system-driven call events (answer/end from the car / Bluetooth
        // device, mute changes) up to the Dart call engine.
        CallRegistry.listener = { event, callId, muted ->
            telecomMc?.invokeMethod(
                event, mapOf("callId" to callId, "muted" to muted)
            )
        }

        val cmc = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, connectedContactsChannel)
        contactsMc = cmc
        cmc.setMethodCallHandler { call, result ->
            when (call.method) {
                "ensureAccount" -> result.success(ConnectedContacts.ensureAccount(this))
                "sync" -> {
                    @Suppress("UNCHECKED_CAST")
                    val list = (call.argument<List<Map<String, Any?>>>("matches")
                        ?: emptyList())
                    result.success(ConnectedContacts.sync(this, list))
                }
                "clear" -> { ConnectedContacts.clearAll(this); result.success(true) }
                "consumePendingAction" -> {
                    val p = pendingContactAction
                    pendingContactAction = null
                    result.success(p)
                }
                else -> result.notImplemented()
            }
        }
        // If the app was cold-launched by tapping an Aluta row in the Contacts
        // app, stash that action for Dart to pick up via consumePendingAction.
        handleContactIntent(intent, deliver = false)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // App already running → deliver straight to Dart.
        handleContactIntent(intent, deliver = true)
    }

    // Turn an ACTION_VIEW on one of Aluta's custom contact mimetypes into a
    // routing payload {action, number, userId}; deliver it now (warm) or stash
    // it for consumePendingAction (cold start).
    private fun handleContactIntent(intent: Intent?, deliver: Boolean) {
        if (intent == null || intent.action != Intent.ACTION_VIEW) return
        val type = intent.type ?: return
        if (type != ConnectedContacts.MIME_CALL && type != ConnectedContacts.MIME_MESSAGE) return
        val uri = intent.data ?: return
        val payload = ConnectedContacts.readAction(this, uri) ?: return
        val mc = contactsMc
        if (deliver && mc != null) {
            mc.invokeMethod("onAction", payload)
        } else {
            pendingContactAction = payload
        }
    }

    // ── Telecom (self-managed calls: car / Bluetooth answer-hangup) ──────────

    private fun handleTelecom(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result
    ) {
        when (call.method) {
            "isSupported" ->
                result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            "register" -> result.success(registerTelecom())
            "reportIncoming" -> result.success(
                reportIncoming(
                    call.argument<String>("callId") ?: "",
                    call.argument<String>("name") ?: "Aluta"
                )
            )
            "startOutgoing" -> result.success(
                startOutgoing(
                    call.argument<String>("callId") ?: "",
                    call.argument<String>("name") ?: "Aluta"
                )
            )
            "setActive" -> {
                CallRegistry.get(call.argument<String>("callId") ?: "")?.setActive()
                result.success(true)
            }
            "endCall" -> {
                CallRegistry.get(call.argument<String>("callId") ?: "")
                    ?.close(DisconnectCause.LOCAL)
                result.success(true)
            }
            "setAudioRoute" -> {
                val id = call.argument<String>("callId") ?: ""
                val route = call.argument<Int>("route") ?: CallAudioState.ROUTE_EARPIECE
                try {
                    CallRegistry.get(id)?.setAudioRoute(route)
                } catch (_: Exception) {}
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun telecomHandle(): PhoneAccountHandle =
        PhoneAccountHandle(ComponentName(this, AlutaConnectionService::class.java), "aluta_voice")

    private fun registerTelecom(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            val tm = getSystemService(Context.TELECOM_SERVICE) as TelecomManager
            val account = PhoneAccount.builder(telecomHandle(), "Aluta")
                .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED)
                .build()
            tm.registerPhoneAccount(account)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun reportIncoming(callId: String, name: String): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || callId.isEmpty()) return false
        return try {
            val tm = getSystemService(Context.TELECOM_SERVICE) as TelecomManager
            val app = Bundle().apply {
                putString(AlutaConnectionService.EXTRA_CALL_ID, callId)
                putString(AlutaConnectionService.EXTRA_CALLER_NAME, name)
            }
            val extras = Bundle().apply {
                putBundle(TelecomManager.EXTRA_INCOMING_CALL_EXTRAS, app)
            }
            tm.addNewIncomingCall(telecomHandle(), extras)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun startOutgoing(callId: String, name: String): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || callId.isEmpty()) return false
        return try {
            val tm = getSystemService(Context.TELECOM_SERVICE) as TelecomManager
            val app = Bundle().apply {
                putString(AlutaConnectionService.EXTRA_CALL_ID, callId)
                putString(AlutaConnectionService.EXTRA_CALLER_NAME, name)
            }
            val extras = Bundle().apply {
                putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, telecomHandle())
                putBundle(TelecomManager.EXTRA_OUTGOING_CALL_EXTRAS, app)
            }
            val uri = Uri.fromParts(PhoneAccount.SCHEME_SIP, "aluta", null)
            tm.placeCall(uri, extras)
            true
        } catch (e: SecurityException) {
            false
        } catch (e: Exception) {
            false
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
