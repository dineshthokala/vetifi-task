"""
Ed25519 signing and verification utilities for the Vetifi dataset server.

The signing key is loaded from, in order of preference:

  1. the ED25519_PRIVATE_KEY environment variable (hex)
  2. server/keys/private.hex
  3. keys/generate_keys.py, run automatically on startup if neither exists

Step 3 exists so `docker compose up` works with no setup, as the brief requires.
It is safe only because the app's public key is compiled in and cannot match a
freshly generated key: the result is that the server starts and signs, and the
app correctly rejects everything, rather than the server refusing to boot.
A loud warning is printed so this is not mistaken for a working setup.

Production should set ED25519_PRIVATE_KEY from a secrets manager. See
DECISIONS.md question 5 for what a leak of this key costs.
"""

import hashlib
import os
import sys
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ed25519

KEYS_DIR = Path(__file__).resolve().parent.parent / "keys"
PRIVATE_KEY_PATH = KEYS_DIR / "private.hex"
PUBLIC_KEY_PATH = KEYS_DIR / "public.hex"

_private_key: ed25519.Ed25519PrivateKey | None = None
_public_key: ed25519.Ed25519PublicKey | None = None


def _load_keys():
    global _private_key, _public_key
    if _private_key is not None and _public_key is not None:
        return

    priv_hex = os.environ.get("ED25519_PRIVATE_KEY", "").strip()
    source = "ED25519_PRIVATE_KEY"

    if not priv_hex and PRIVATE_KEY_PATH.exists():
        priv_hex = PRIVATE_KEY_PATH.read_text(encoding="utf-8").strip()
        source = str(PRIVATE_KEY_PATH)

    if not priv_hex:
        # Generate on first run so the demo works with zero setup. The public
        # key derived here will not match the one compiled into the app, so
        # updates will be rejected -- which is the correct behaviour for an
        # untrusted key, and much better than a silent misconfiguration.
        priv_hex = _generate_keypair()
        source = "generated on startup"

    _private_key = ed25519.Ed25519PrivateKey.from_private_bytes(
        bytes.fromhex(priv_hex)
    )
    _public_key = _private_key.public_key()

    if source == "generated on startup":
        print(
            "\n"
            "  " + "=" * 70 + "\n"
            "  WARNING: a NEW signing key was generated for this process.\n"
            "  The app's compiled-in public key will NOT match it, so every\n"
            "  update will be rejected by the app. That is the safe outcome.\n"
            "\n"
            "  For a working setup, set ED25519_PRIVATE_KEY, or keep a stable\n"
            "  key at server/keys/private.hex (see keys/generate_keys.py).\n"
            + "  " + "=" * 70 + "\n",
            file=sys.stderr,
        )


def _generate_keypair() -> str:
    key = ed25519.Ed25519PrivateKey.generate()
    private_hex = key.private_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PrivateFormat.Raw,
        encryption_algorithm=serialization.NoEncryption(),
    ).hex()
    public_hex = key.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    ).hex()

    try:
        KEYS_DIR.mkdir(parents=True, exist_ok=True)
        PRIVATE_KEY_PATH.write_text(private_hex + "\n", encoding="utf-8")
        PUBLIC_KEY_PATH.write_text(public_hex + "\n", encoding="utf-8")
    except OSError:
        # A read-only container is fine; the key simply lives in memory.
        pass

    return private_hex


def get_public_key_hex() -> str:
    _load_keys()
    assert _public_key is not None
    pub_bytes = _public_key.public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw
    )
    return pub_bytes.hex()


def sign_data(data: bytes | str) -> str:
    """Signs data (bytes or UTF-8 str) with server's Ed25519 private key, returns hex signature."""
    _load_keys()
    assert _private_key is not None
    raw = data.encode("utf-8") if isinstance(data, str) else data
    sig = _private_key.sign(raw)
    return sig.hex()


def verify_signature(data: bytes | str, signature_hex: str, public_key_hex: str | None = None) -> bool:
    """Verifies signature against public key."""
    try:
        raw = data.encode("utf-8") if isinstance(data, str) else data
        sig_bytes = bytes.fromhex(signature_hex)
        if public_key_hex:
            pub_key = ed25519.Ed25519PublicKey.from_public_bytes(bytes.fromhex(public_key_hex))
        else:
            _load_keys()
            assert _public_key is not None
            pub_key = _public_key
        pub_key.verify(sig_bytes, raw)
        return True
    except Exception:
        return False


def compute_sha256(data: bytes | str) -> str:
    """Computes SHA-256 hash of data in hex."""
    raw = data.encode("utf-8") if isinstance(data, str) else data
    return hashlib.sha256(raw).hexdigest()
