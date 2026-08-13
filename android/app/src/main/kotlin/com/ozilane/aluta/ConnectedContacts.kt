package com.ozilane.aluta

import android.accounts.Account
import android.accounts.AccountManager
import android.content.ContentProviderOperation
import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.provider.ContactsContract
import android.provider.ContactsContract.CommonDataKinds.Phone
import android.provider.ContactsContract.CommonDataKinds.StructuredName
import android.provider.ContactsContract.Data
import android.provider.ContactsContract.RawContacts

/**
 * Writes Aluta's "Connected apps" rows onto matching device contacts, the same
 * way WhatsApp / Telegram do: a stub sync account (see AlutaAuthenticator +
 * AlutaContactsSyncService) owns a RawContact per registered friend, and Android
 * aggregates it into the phone-book contact that shares the number. Two custom
 * data rows (call + message) then render under that contact and, when tapped,
 * fire ACTION_VIEW back into MainActivity, which routes into Aluta.
 *
 * All writes are driven on demand from Dart (ConnectedContactsService) rather
 * than from onPerformSync, so the sync adapter itself stays a no-op stub.
 */
object ConnectedContacts {
    const val ACCOUNT_TYPE = "com.ozilane.aluta"
    const val ACCOUNT_NAME = "Aluta"
    const val MIME_CALL = "vnd.android.cursor.item/vnd.com.ozilane.aluta.call"
    const val MIME_MESSAGE = "vnd.android.cursor.item/vnd.com.ozilane.aluta.message"

    private fun account() = Account(ACCOUNT_NAME, ACCOUNT_TYPE)

    /** Create the stub Aluta account (idempotent) and enable contacts sync for
     *  it so its raw contacts survive and aggregate. */
    fun ensureAccount(ctx: Context): Boolean {
        return try {
            val am = AccountManager.get(ctx)
            val acc = account()
            val exists = am.getAccountsByType(ACCOUNT_TYPE).any { it.name == ACCOUNT_NAME }
            if (!exists) am.addAccountExplicitly(acc, null, null)
            ContentResolver.setIsSyncable(acc, ContactsContract.AUTHORITY, 1)
            ContentResolver.setSyncAutomatically(acc, ContactsContract.AUTHORITY, true)
            true
        } catch (e: Exception) {
            false
        }
    }

    /** Reconcile the account's raw contacts against [matches] (each a map with
     *  string keys "userId", "number", "name"): insert any missing, prune any
     *  no longer registered. Idempotent — keyed by SOURCE_ID = Aluta user id. */
    fun sync(ctx: Context, matches: List<Map<String, Any?>>): Boolean {
        if (!ensureAccount(ctx)) return false
        val cr = ctx.contentResolver
        val wantIds = HashSet<String>()
        for (m in matches) m["userId"]?.toString()?.let { wantIds.add(it) }

        // Existing raw contacts for our account: sourceId -> rawContactId.
        val existing = HashMap<String, Long>()
        try {
            cr.query(
                RawContacts.CONTENT_URI,
                arrayOf(RawContacts._ID, RawContacts.SOURCE_ID),
                "${RawContacts.ACCOUNT_TYPE}=? AND ${RawContacts.ACCOUNT_NAME}=?",
                arrayOf(ACCOUNT_TYPE, ACCOUNT_NAME),
                null
            )?.use { c ->
                val idIdx = c.getColumnIndexOrThrow(RawContacts._ID)
                val srcIdx = c.getColumnIndexOrThrow(RawContacts.SOURCE_ID)
                while (c.moveToNext()) {
                    val src = c.getString(srcIdx) ?: continue
                    existing[src] = c.getLong(idIdx)
                }
            }
        } catch (_: Exception) {
        }

        // Insert the ones we don't have yet.
        for (m in matches) {
            val userId = m["userId"]?.toString() ?: continue
            val number = m["number"]?.toString()?.trim() ?: continue
            if (number.isEmpty() || existing.containsKey(userId)) continue
            val name = m["name"]?.toString()?.takeIf { it.isNotBlank() } ?: "Aluta user"
            insertRaw(cr, userId, number, name)
        }

        // Remove the ones that are no longer registered friends.
        for ((src, rawId) in existing) {
            if (!wantIds.contains(src)) {
                try {
                    cr.delete(syncUri(RawContacts.CONTENT_URI),
                        "${RawContacts._ID}=?", arrayOf(rawId.toString()))
                } catch (_: Exception) {
                }
            }
        }
        return true
    }

    private fun insertRaw(cr: ContentResolver, userId: String, number: String, name: String) {
        val ops = ArrayList<ContentProviderOperation>()
        val raw = 0
        ops.add(
            ContentProviderOperation.newInsert(syncUri(RawContacts.CONTENT_URI))
                .withValue(RawContacts.ACCOUNT_TYPE, ACCOUNT_TYPE)
                .withValue(RawContacts.ACCOUNT_NAME, ACCOUNT_NAME)
                .withValue(RawContacts.SOURCE_ID, userId)
                .build()
        )
        ops.add(
            ContentProviderOperation.newInsert(syncUri(Data.CONTENT_URI))
                .withValueBackReference(Data.RAW_CONTACT_ID, raw)
                .withValue(Data.MIMETYPE, StructuredName.CONTENT_ITEM_TYPE)
                .withValue(StructuredName.DISPLAY_NAME, name)
                .build()
        )
        // A Phone row with the matched number is what makes Android aggregate
        // this raw contact into the existing phone-book contact.
        ops.add(
            ContentProviderOperation.newInsert(syncUri(Data.CONTENT_URI))
                .withValueBackReference(Data.RAW_CONTACT_ID, raw)
                .withValue(Data.MIMETYPE, Phone.CONTENT_ITEM_TYPE)
                .withValue(Phone.NUMBER, number)
                .withValue(Phone.TYPE, Phone.TYPE_OTHER)
                .build()
        )
        ops.add(customRow(raw, MIME_CALL, number, userId, "Aluta", "Voice call on Aluta"))
        ops.add(customRow(raw, MIME_MESSAGE, number, userId, "Aluta", "Message on Aluta"))
        try {
            cr.applyBatch(ContactsContract.AUTHORITY, ops)
        } catch (_: Exception) {
        }
    }

    private fun customRow(
        raw: Int, mime: String, number: String, userId: String,
        summary: String, detail: String
    ): ContentProviderOperation =
        ContentProviderOperation.newInsert(syncUri(Data.CONTENT_URI))
            .withValueBackReference(Data.RAW_CONTACT_ID, raw)
            .withValue(Data.MIMETYPE, mime)
            .withValue(Data.DATA1, number)   // generic id + routing
            .withValue(Data.DATA2, summary)  // summaryColumn in aluta_contacts.xml
            .withValue(Data.DATA3, detail)   // detailColumn  in aluta_contacts.xml
            .withValue(Data.DATA4, userId)   // Aluta user id, for routing
            .build()

    /** Append the sync-adapter query params so writes are attributed to our
     *  account (and not treated as user edits). */
    private fun syncUri(uri: Uri): Uri = uri.buildUpon()
        .appendQueryParameter(ContactsContract.CALLER_IS_SYNCADAPTER, "true")
        .appendQueryParameter(RawContacts.ACCOUNT_NAME, ACCOUNT_NAME)
        .appendQueryParameter(RawContacts.ACCOUNT_TYPE, ACCOUNT_TYPE)
        .build()

    /** Delete every Aluta raw contact (e.g. on logout). */
    fun clearAll(ctx: Context) {
        try {
            ctx.contentResolver.delete(
                syncUri(RawContacts.CONTENT_URI),
                "${RawContacts.ACCOUNT_TYPE}=? AND ${RawContacts.ACCOUNT_NAME}=?",
                arrayOf(ACCOUNT_TYPE, ACCOUNT_NAME)
            )
        } catch (_: Exception) {
        }
    }

    /** Resolve a tapped data-row Uri (content://com.android.contacts/data/<id>)
     *  into a routing payload {action, number, userId}, or null if it isn't one
     *  of ours. */
    fun readAction(ctx: Context, dataUri: Uri): HashMap<String, String>? {
        return try {
            ctx.contentResolver.query(
                dataUri,
                arrayOf(Data.MIMETYPE, Data.DATA1, Data.DATA4),
                null, null, null
            )?.use { c ->
                if (!c.moveToFirst()) return null
                val mime = c.getString(0) ?: return null
                val number = c.getString(1) ?: ""
                val userId = c.getString(2) ?: ""
                val action = when (mime) {
                    MIME_CALL -> "call"
                    MIME_MESSAGE -> "message"
                    else -> return null
                }
                hashMapOf("action" to action, "number" to number, "userId" to userId)
            }
        } catch (e: Exception) {
            null
        }
    }
}
