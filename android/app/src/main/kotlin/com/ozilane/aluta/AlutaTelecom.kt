package com.ozilane.aluta

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.telecom.CallAudioState
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.DisconnectCause
import android.telecom.PhoneAccountHandle

/// Self-managed Telecom integration for Aluta's WebRTC voice/group calls.
///
/// Registering each call with the platform's telecom stack is what lets a car
/// head-unit or Bluetooth headset see an Aluta call as a real call — so its
/// answer/end button works and audio routes over the hands-free profile. This
/// is DELIBERATELY ADDITIVE: the app keeps its own ring UI + WebRTC signalling;
/// telecom just mirrors the call so the system/car can drive it. Everything is
/// guarded so a device that doesn't support self-managed calls (some MIUI ROMs)
/// silently falls back to the existing in-app flow.
///
/// Events the system raises on a call (the user pressed answer/end on the car,
/// toggled mute, or the audio route changed) are forwarded to Dart through
/// [CallRegistry.listener]; Dart drives the actual WebRTC accept/hangup.
object CallRegistry {
    /// Emits telecom events up to MainActivity → Dart. Args: (event, callId, extra).
    /// event ∈ {"answer","disconnect","reject","mute","unmute"}.
    var listener: ((event: String, callId: String, muted: Boolean) -> Unit)? = null

    private val connections = HashMap<String, AlutaConnection>()

    fun put(callId: String, c: AlutaConnection) {
        connections[callId] = c
    }

    fun get(callId: String): AlutaConnection? = connections[callId]

    fun remove(callId: String) {
        connections.remove(callId)
    }

    fun emit(event: String, callId: String, muted: Boolean = false) {
        val l = listener ?: return
        Handler(Looper.getMainLooper()).post { l(event, callId, muted) }
    }
}

/// One telecom-visible Aluta call. The system calls these overrides when the
/// user acts on the call from the car / system UI; we forward to Dart and let
/// the WebRTC layer do the real work, then reflect state back with setActive()
/// / setDisconnected().
class AlutaConnection(val callId: String) : Connection() {

    init {
        setConnectionProperties(PROPERTY_SELF_MANAGED)
        setAudioModeIsVoip(true)
        setConnectionCapabilities(CAPABILITY_MUTE or CAPABILITY_SUPPORT_HOLD or CAPABILITY_HOLD)
    }

    override fun onAnswer() {
        CallRegistry.emit("answer", callId)
        setActive()
    }

    override fun onReject() {
        CallRegistry.emit("reject", callId)
        close(DisconnectCause.REJECTED)
    }

    override fun onDisconnect() {
        CallRegistry.emit("disconnect", callId)
        close(DisconnectCause.LOCAL)
    }

    override fun onAbort() {
        CallRegistry.emit("disconnect", callId)
        close(DisconnectCause.CANCELED)
    }

    override fun onHold() {
        setOnHold()
    }

    override fun onUnhold() {
        setActive()
    }

    override fun onCallAudioStateChanged(state: CallAudioState?) {
        state ?: return
        CallRegistry.emit(if (state.isMuted) "mute" else "unmute", callId, state.isMuted)
    }

    fun close(cause: Int) {
        setDisconnected(DisconnectCause(cause))
        destroy()
        CallRegistry.remove(callId)
    }
}

/// The ConnectionService the platform instantiates to create incoming/outgoing
/// self-managed connections. Registered in the manifest.
class AlutaConnectionService : ConnectionService() {

    override fun onCreateIncomingConnection(
        handle: PhoneAccountHandle?,
        request: ConnectionRequest?
    ): Connection {
        return build(request, incoming = true)
    }

    override fun onCreateOutgoingConnection(
        handle: PhoneAccountHandle?,
        request: ConnectionRequest?
    ): Connection {
        return build(request, incoming = false)
    }

    private fun build(request: ConnectionRequest?, incoming: Boolean): Connection {
        val root: Bundle = request?.extras ?: Bundle()
        // Telecom nests the app-supplied extras under a well-known key (incoming
        // vs outgoing); fall back to the root bundle if not present.
        val nestedKey =
            if (incoming) android.telecom.TelecomManager.EXTRA_INCOMING_CALL_EXTRAS
            else android.telecom.TelecomManager.EXTRA_OUTGOING_CALL_EXTRAS
        val extras: Bundle = root.getBundle(nestedKey) ?: root
        val callId = extras.getString(EXTRA_CALL_ID) ?: "aluta_call"
        val name = extras.getString(EXTRA_CALLER_NAME) ?: "Aluta"
        val conn = AlutaConnection(callId)
        conn.setCallerDisplayName(name, android.telecom.TelecomManager.PRESENTATION_ALLOWED)
        conn.setAudioModeIsVoip(true)
        if (incoming) {
            conn.setRinging()
        } else {
            conn.setDialing()
        }
        CallRegistry.put(callId, conn)
        return conn
    }

    companion object {
        const val EXTRA_CALL_ID = "aluta_call_id"
        const val EXTRA_CALLER_NAME = "aluta_caller_name"
    }
}
