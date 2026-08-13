package com.ozilane.aluta

import android.accounts.Account
import android.app.Service
import android.content.AbstractThreadedSyncAdapter
import android.content.ContentProviderClient
import android.content.Context
import android.content.Intent
import android.content.SyncResult
import android.os.Bundle
import android.os.IBinder

/**
 * The contacts sync adapter for the Aluta account. Aluta writes its "Connected
 * apps" rows on demand from the app (see ConnectedContacts), so this performs no
 * server-driven sync — it exists so the account is a valid ContactsContract
 * source (with res/xml/aluta_contacts.xml attached via CONTACTS_STRUCTURE).
 */
class AlutaContactsSyncService : Service() {
    private val adapter by lazy { AlutaSyncAdapter(applicationContext, true) }
    override fun onBind(intent: Intent?): IBinder = adapter.syncAdapterBinder
}

class AlutaSyncAdapter(context: Context, autoInitialize: Boolean) :
    AbstractThreadedSyncAdapter(context, autoInitialize) {
    override fun onPerformSync(
        account: Account?,
        extras: Bundle?,
        authority: String?,
        provider: ContentProviderClient?,
        syncResult: SyncResult?
    ) {
        // No-op: rows are written on demand from the Flutter side.
    }
}
