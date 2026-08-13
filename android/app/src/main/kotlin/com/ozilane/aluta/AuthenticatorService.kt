package com.ozilane.aluta

import android.app.Service
import android.content.Intent
import android.os.IBinder

/** Binds the stub AlutaAuthenticator so the system recognises the Aluta account
 *  type (declared in res/xml/aluta_authenticator.xml). */
class AuthenticatorService : Service() {
    private val authenticator by lazy { AlutaAuthenticator(this) }
    override fun onBind(intent: Intent?): IBinder = authenticator.iBinder
}
