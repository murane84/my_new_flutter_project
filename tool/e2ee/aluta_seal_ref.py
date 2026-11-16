"""Aluta Seal v1 — reference implementation (Python) used to produce the test
vectors for the Dart implementation. Signal's published design (X3DH +
Double Ratchet), Aluta's own constants:

Keys
  identity: Ed25519 signing key (the trust anchor, safety numbers) +
            X25519 DH identity key, its public part signed by the Ed25519 key.
  signed prekey (SPK): X25519, signed by the Ed25519 key.
  one-time prekeys (OPK): X25519.

X3DH (initiator A → responder B)
  DH1 = DH(IKdh_A, SPK_B)   DH2 = DH(EK_A, IKdh_B)
  DH3 = DH(EK_A, SPK_B)     DH4 = DH(EK_A, OPK_B)   (if an OPK was used)
  SK  = HKDF-SHA256(salt = 32×0x00, ikm = 32×0xFF ‖ DH1 ‖ DH2 ‖ DH3 [‖ DH4],
                    info = "AlutaSeal X3DH v1", 32 bytes)
  AD  = IKsig_A ‖ IKsig_B      (initiator first, 32 + 32 bytes)

Double Ratchet
  KDF_RK(rk, dh) = HKDF-SHA256(salt = rk, ikm = dh,
                               info = "AlutaSeal Ratchet v1", 64) → rk', ck
  KDF_CK(ck)     = mk = HMAC-SHA256(ck, 0x01), ck' = HMAC-SHA256(ck, 0x02)
  Message keys   = HKDF-SHA256(salt = 32×0x00, ikm = mk,
                               info = "AlutaSeal Message v1", 44)
                   → aes key (32) ‖ nonce (12)
  AEAD           = AES-256-GCM, aad = AD ‖ header, output = ct ‖ tag(16)
  header         = dh_pub (32) ‖ pn (u32 BE) ‖ n (u32 BE)    (40 bytes)
  A starts:  DHs = fresh, DHr = SPK_B, (RK, CKs) = KDF_RK(SK, DH(DHs, DHr))
  B starts:  DHs = SPK_B pair, RK = SK

Run: python tool/e2ee/aluta_seal_ref.py  (needs `pip install cryptography`);
its output is pasted into test/e2ee_test.dart.
"""
import hashlib
import hmac
import json
from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey, X25519PublicKey)
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey, Ed25519PublicKey)
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

RAW = serialization.Encoding.Raw
PUBRAW = serialization.PublicFormat.Raw
PRIVRAW = serialization.PrivateFormat.Raw
NOENC = serialization.NoEncryption()

INFO_X3DH = b"AlutaSeal X3DH v1"
INFO_RK = b"AlutaSeal Ratchet v1"
INFO_MSG = b"AlutaSeal Message v1"
SPK_SIG_PREFIX = b"AlutaSeal SPK v1"
IKDH_SIG_PREFIX = b"AlutaSeal IKDH v1"


def hkdf(salt, ikm, info, n):
    return HKDF(algorithm=hashes.SHA256(), length=n, salt=salt,
                info=info).derive(ikm)


def x_pair(seed):
    k = X25519PrivateKey.from_private_bytes(seed)
    return k, k.public_key().public_bytes(RAW, PUBRAW)


def ed_pair(seed):
    k = Ed25519PrivateKey.from_private_bytes(seed)
    return k, k.public_key().public_bytes(RAW, PUBRAW)


def dh(priv, pub_bytes):
    return priv.exchange(X25519PublicKey.from_public_bytes(pub_bytes))


def kdf_rk(rk, dh_out):
    o = hkdf(rk, dh_out, INFO_RK, 64)
    return o[:32], o[32:]


def kdf_ck(ck):
    return (hmac.new(ck, b"\x02", hashlib.sha256).digest(),
            hmac.new(ck, b"\x01", hashlib.sha256).digest())


def header(dh_pub, pn, n):
    return dh_pub + pn.to_bytes(4, "big") + n.to_bytes(4, "big")


def seal(mk, pt, aad):
    km = hkdf(b"\x00" * 32, mk, INFO_MSG, 44)
    return AESGCM(km[:32]).encrypt(km[32:], pt, aad)


def unseal(mk, ct, aad):
    km = hkdf(b"\x00" * 32, mk, INFO_MSG, 44)
    return AESGCM(km[:32]).decrypt(km[32:], ct, aad)


def seed(tag):
    return hashlib.sha256(b"aluta-seal-test:" + tag.encode()).digest()


class Ratchet:
    def __init__(self, ad):
        self.ad = ad
        self.dhs = None  # (priv, pub)
        self.dhr = None
        self.rk = None
        self.cks = None
        self.ckr = None
        self.ns = self.nr = self.pn = 0
        self.skipped = {}

    @classmethod
    def init_a(cls, sk, ad, b_spk_pub, dhs_seed):
        r = cls(ad)
        r.dhs = x_pair(dhs_seed)
        r.dhr = b_spk_pub
        r.rk, r.cks = kdf_rk(sk, dh(r.dhs[0], r.dhr))
        return r

    @classmethod
    def init_b(cls, sk, ad, spk_pair):
        r = cls(ad)
        r.dhs = spk_pair
        r.rk = sk
        return r

    def encrypt(self, pt):
        self.cks, mk = kdf_ck(self.cks)
        h = header(self.dhs[1], self.pn, self.ns)
        self.ns += 1
        return h, seal(mk, pt, self.ad + h)

    def decrypt(self, h, ct, next_dhs_seed):
        dh_pub = h[:32]
        pn = int.from_bytes(h[32:36], "big")
        n = int.from_bytes(h[36:40], "big")
        key = (dh_pub, n)
        if key in self.skipped:
            mk = self.skipped.pop(key)
            return unseal(mk, ct, self.ad + h)
        if dh_pub != self.dhr:
            self._skip(pn)
            self.pn = self.ns
            self.ns = self.nr = 0
            self.dhr = dh_pub
            self.rk, self.ckr = kdf_rk(self.rk, dh(self.dhs[0], self.dhr))
            self.dhs = x_pair(next_dhs_seed)
            self.rk, self.cks = kdf_rk(self.rk, dh(self.dhs[0], self.dhr))
        self._skip(n)
        self.ckr, mk = kdf_ck(self.ckr)
        self.nr += 1
        return unseal(mk, ct, self.ad + h)

    def _skip(self, until):
        if self.ckr is None:
            return
        while self.nr < until:
            self.ckr, mk = kdf_ck(self.ckr)
            self.skipped[(self.dhr, self.nr)] = mk
            self.nr += 1


def main():
    # Bob's published keys
    b_sig, b_sig_pub = ed_pair(seed("bob-ik-sig"))
    b_ikdh, b_ikdh_pub = x_pair(seed("bob-ik-dh"))
    b_spk, b_spk_pub = x_pair(seed("bob-spk"))
    b_opk, b_opk_pub = x_pair(seed("bob-opk-1"))
    spk_sig = b_sig.sign(SPK_SIG_PREFIX + b_spk_pub)
    ikdh_sig = b_sig.sign(IKDH_SIG_PREFIX + b_ikdh_pub)
    # Alice
    a_sig, a_sig_pub = ed_pair(seed("alice-ik-sig"))
    a_ikdh, a_ikdh_pub = x_pair(seed("alice-ik-dh"))
    a_ek, a_ek_pub = x_pair(seed("alice-ek"))

    dh1 = dh(a_ikdh, b_spk_pub)
    dh2 = dh(a_ek, b_ikdh_pub)
    dh3 = dh(a_ek, b_spk_pub)
    dh4 = dh(a_ek, b_opk_pub)
    sk_a = hkdf(b"\x00" * 32, b"\xff" * 32 + dh1 + dh2 + dh3 + dh4, INFO_X3DH, 32)
    # Bob's side
    sk_b = hkdf(b"\x00" * 32,
                b"\xff" * 32 + dh(b_spk, a_ikdh_pub) + dh(b_ikdh, a_ek_pub)
                + dh(b_spk, a_ek_pub) + dh(b_opk, a_ek_pub), INFO_X3DH, 32)
    assert sk_a == sk_b
    sk_no_opk = hkdf(b"\x00" * 32, b"\xff" * 32 + dh1 + dh2 + dh3, INFO_X3DH, 32)
    ad = a_sig_pub + b_sig_pub

    A = Ratchet.init_a(sk_a, ad, b_spk_pub, seed("alice-ratchet-1"))
    B = Ratchet.init_b(sk_b, ad, (b_spk, b_spk_pub))

    msgs = []
    def a_send(t):
        h, c = A.encrypt(t.encode()); msgs.append(("A", t, h, c)); return h, c
    def b_send(t):
        h, c = B.encrypt(t.encode()); msgs.append(("B", t, h, c)); return h, c

    h1, c1 = a_send("Habari za jioni? 🎶")
    h2, c2 = a_send("Twende tuisikilize pamoja")
    assert B.decrypt(h1, c1, seed("bob-ratchet-1")) == "Habari za jioni? 🎶".encode()
    assert B.decrypt(h2, c2, seed("bob-ratchet-1-unused")) == b"Twende tuisikilize pamoja"
    h3, c3 = b_send("Ndiyo! saa mbili usiku")
    assert A.decrypt(h3, c3, seed("alice-ratchet-2")) == "Ndiyo! saa mbili usiku".encode()
    # out of order: A sends 2, B reads the second first
    h4, c4 = a_send("ya kwanza")
    h5, c5 = a_send("ya pili")
    assert B.decrypt(h5, c5, seed("bob-ratchet-2")) == b"ya pili"
    assert B.decrypt(h4, c4, seed("bob-ratchet-2-unused")) == b"ya kwanza"

    hx = lambda b: b.hex()
    out = {
        "spec": "AlutaSeal v1",
        "seeds": {k: hx(seed(k)) for k in [
            "bob-ik-sig", "bob-ik-dh", "bob-spk", "bob-opk-1", "alice-ik-sig",
            "alice-ik-dh", "alice-ek", "alice-ratchet-1", "bob-ratchet-1",
            "alice-ratchet-2", "bob-ratchet-2"]},
        "pub": {"bob_sig": hx(b_sig_pub), "bob_ikdh": hx(b_ikdh_pub),
                "bob_spk": hx(b_spk_pub), "bob_opk": hx(b_opk_pub),
                "alice_sig": hx(a_sig_pub), "alice_ikdh": hx(a_ikdh_pub),
                "alice_ek": hx(a_ek_pub)},
        "spk_sig": hx(spk_sig), "ikdh_sig": hx(ikdh_sig),
        "x3dh_sk": hx(sk_a), "x3dh_sk_no_opk": hx(sk_no_opk),
        "messages": [{"from": f, "text": t, "header": hx(h), "ct": hx(c)}
                     for f, t, h, c in msgs],
    }
    print(json.dumps(out, indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()
