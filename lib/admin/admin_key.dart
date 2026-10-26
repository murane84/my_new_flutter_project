// The admin device key lives in the browser: a NON-extractable ECDSA P-256
// key (WebCrypto) kept in IndexedDB. Its private half can sign but can never be
// read out or copied — so a leaked password or a stolen session token is
// useless on any other machine. Web-only (the admin app is a web build).
// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

extension type _KeyApi._(JSObject _) implements JSObject {
  external JSPromise<JSBoolean> supported();
  external JSPromise<JSString> publicKey();
  external JSPromise<JSString> sign(JSString message);
  external JSPromise<JSString> sha256(JSString message);
  external JSPromise<JSBoolean> persist();
}

const String _js = r'''
globalThis.alutaAdminKey = (function () {
  var DB = 'aluta_admin', STORE = 'keys', ID = 'device', cached = null;
  function openDb() {
    return new Promise(function (res, rej) {
      var r = indexedDB.open(DB, 1);
      r.onupgradeneeded = function () { r.result.createObjectStore(STORE); };
      r.onsuccess = function () { res(r.result); };
      r.onerror = function () { rej(r.error); };
    });
  }
  function getKp() {
    return openDb().then(function (db) {
      return new Promise(function (res, rej) {
        var q = db.transaction(STORE, 'readonly').objectStore(STORE).get(ID);
        q.onsuccess = function () { res(q.result || null); };
        q.onerror = function () { rej(q.error); };
      });
    });
  }
  function putKp(kp) {
    return openDb().then(function (db) {
      return new Promise(function (res, rej) {
        var tx = db.transaction(STORE, 'readwrite');
        tx.objectStore(STORE).put(kp, ID);
        tx.oncomplete = function () { res(true); };
        tx.onerror = function () { rej(tx.error); };
      });
    });
  }
  function b64(buf) {
    var s = '', a = new Uint8Array(buf);
    for (var i = 0; i < a.length; i++) s += String.fromCharCode(a[i]);
    return btoa(s);
  }
  async function pair() {
    if (cached) return cached;
    var kp = await getKp();
    if (!kp) {
      kp = await crypto.subtle.generateKey(
        { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign', 'verify']);
      await putKp(kp);
    }
    cached = kp;
    return kp;
  }
  return {
    supported: async function () {
      return !!(globalThis.isSecureContext && globalThis.crypto &&
        crypto.subtle && globalThis.indexedDB);
    },
    publicKey: async function () {
      var kp = await pair();
      return b64(await crypto.subtle.exportKey('spki', kp.publicKey));
    },
    sign: async function (msg) {
      var kp = await pair();
      return b64(await crypto.subtle.sign(
        { name: 'ECDSA', hash: 'SHA-256' }, kp.privateKey,
        new TextEncoder().encode(msg)));
    },
    sha256: async function (msg) {
      var d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(msg));
      return Array.from(new Uint8Array(d)).map(function (b) {
        return b.toString(16).padStart(2, '0');
      }).join('');
    },
    persist: async function () {
      try {
        if (navigator.storage && navigator.storage.persist) {
          return await navigator.storage.persist();
        }
      } catch (e) {}
      return false;
    }
  };
})();
''';

class AdminKey {
  AdminKey._();

  static _KeyApi? _api;

  static _KeyApi _ensure() {
    final existing = _api;
    if (existing != null) return existing;
    if (!globalContext.has('alutaAdminKey')) {
      globalContext.callMethod('eval'.toJS, _js.toJS);
    }
    final api = globalContext.getProperty<_KeyApi>('alutaAdminKey'.toJS);
    _api = api;
    return api;
  }

  /// False on a non-HTTPS page or a browser without WebCrypto / IndexedDB.
  static Future<bool> supported() async {
    try {
      return (await _ensure().supported().toDart).toDart;
    } catch (_) {
      return false;
    }
  }

  /// This device's public key (base64 SPKI). Creates the key on first use.
  static Future<String> publicKey() async =>
      (await _ensure().publicKey().toDart).toDart;

  /// Signs [message] → base64 raw r||s (64 bytes).
  static Future<String> sign(String message) async =>
      (await _ensure().sign(message.toJS).toDart).toDart;

  static Future<String> sha256Hex(String message) async =>
      (await _ensure().sha256(message.toJS).toDart).toDart;

  /// Ask the browser not to evict this site's storage (keeps the key).
  static Future<void> persist() async {
    try {
      await _ensure().persist().toDart;
    } catch (_) {}
  }
}
