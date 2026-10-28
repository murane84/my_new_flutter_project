package com.ozilane.aluta

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Build
import android.os.IBinder

/// The "In call with … · 02:14" notification while an Aluta call is live, run
/// as a foreground service of type phoneCall|microphone — so the call (and the
/// microphone) keeps working after Aluta goes to the background, e.g. when the
/// call was answered from the banner and the app tucks itself away. Buttons:
/// Mute / Speaker / Hang up (broadcasts → [CallActionReceiver] → Dart through
/// CallRegistry) and a tap that opens the call screen.
class AlutaCallFgService : Service() {
    companion object {
        const val CHANNEL_ID = "aluta_call_ongoing"
        const val NOTIF_ID = 6230
        const val EXTRA_NAME = "name"
        const val EXTRA_SINCE = "since"
        const val EXTRA_MUTED = "muted"
        const val EXTRA_SPEAKER = "speaker"
        const val ACTION_HANGUP = "com.ozilane.aluta.CALL_HANGUP"
        const val ACTION_MUTE = "com.ozilane.aluta.CALL_MUTE"
        const val ACTION_SPEAKER = "com.ozilane.aluta.CALL_SPEAKER"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val name = intent?.getStringExtra(EXTRA_NAME) ?: "Aluta call"
        val since = intent?.getLongExtra(EXTRA_SINCE, System.currentTimeMillis())
            ?: System.currentTimeMillis()
        val muted = intent?.getBooleanExtra(EXTRA_MUTED, false) ?: false
        val speaker = intent?.getBooleanExtra(EXTRA_SPEAKER, false) ?: false
        val notif = build(name, since, muted, speaker)
        try {
            if (Build.VERSION.SDK_INT >= 30) {
                try {
                    startForeground(
                        NOTIF_ID, notif,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL or
                            ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                    )
                } catch (e: Exception) {
                    // Microphone type refused (e.g. started from background) —
                    // keep at least the phone-call service.
                    startForeground(
                        NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
                    )
                }
            } else if (Build.VERSION.SDK_INT >= 29) {
                startForeground(
                    NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
                )
            } else {
                startForeground(NOTIF_ID, notif)
            }
        } catch (e: Exception) {
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun build(name: String, since: Long, muted: Boolean, speaker: Boolean): Notification {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel(CHANNEL_ID) == null) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Ongoing call", NotificationManager.IMPORTANCE_LOW)
                    .apply {
                        description = "Shows while an Aluta call is in progress"
                        setSound(null, null)
                        enableVibration(false)
                    }
            )
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        fun action(act: String, req: Int): PendingIntent = PendingIntent.getBroadcast(
            this, req, Intent(this, CallActionReceiver::class.java).setAction(act), flags
        )
        val open = PendingIntent.getActivity(
            this, 6231,
            Intent(this, MainActivity::class.java)
                .setAction("com.ozilane.aluta.OPEN_CALL")
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            flags
        )
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL_ID)
        else @Suppress("DEPRECATION") Notification.Builder(this)
        b.setSmallIcon(R.mipmap.launcher_icon)
            .setContentTitle(name)
            .setContentText(if (muted) "Aluta call · muted" else "Aluta call")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(true)
            .setWhen(since)
            .setUsesChronometer(true)
            .setCategory(Notification.CATEGORY_CALL)
            .setContentIntent(open)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
        val icon = Icon.createWithResource(this, R.mipmap.launcher_icon)
        b.addAction(Notification.Action.Builder(icon, if (muted) "Unmute" else "Mute",
            action(ACTION_MUTE, 6232)).build())
        b.addAction(Notification.Action.Builder(icon, if (speaker) "Earpiece" else "Speaker",
            action(ACTION_SPEAKER, 6233)).build())
        b.addAction(Notification.Action.Builder(icon, "Hang up",
            action(ACTION_HANGUP, 6234)).build())
        return b.build()
    }

    override fun onDestroy() {
        try {
            if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE)
        } catch (e: Exception) {
        }
        super.onDestroy()
    }
}

/// Buttons on the ongoing-call notification → Dart (via MainActivity's telecom
/// channel). Works while the app is in the background.
class CallActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            AlutaCallFgService.ACTION_HANGUP -> CallRegistry.listener?.invoke("disconnect", "dm_ongoing", false)
            AlutaCallFgService.ACTION_MUTE -> CallRegistry.listener?.invoke("toggleMute", "dm_ongoing", false)
            AlutaCallFgService.ACTION_SPEAKER -> CallRegistry.listener?.invoke("toggleSpeaker", "dm_ongoing", false)
        }
    }
}
