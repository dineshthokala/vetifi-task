"""
Generates the Ed25519 signing keypair used to sign dataset updates.

Run once before first start:

    python server/keys/generate_keys.py

Then set the public key in the app at
`app/lib/services/update_service.dart` (`_compiledInPublicKeyHex`).

This key pair is for local demonstration only. The private key is written to
`server/keys/private.hex`, which is deliberately inside the repository so that a
reviewer can run the whole system with one command. In production the private
key would live in an HSM or a secrets manager and never in a working tree --
which is precisely the leak scenario analysed in DECISIONS.md question 5.
"""

from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ed25519

KEYS_DIR = Path(__file__).resolve().parent
PRIVATE_PATH = KEYS_DIR / "private.hex"
PUBLIC_PATH = KEYS_DIR / "public.hex"


def generate(overwrite: bool = False) -> tuple[str, str]:
    if PRIVATE_PATH.exists() and PUBLIC_PATH.exists() and not overwrite:
        private_hex = PRIVATE_PATH.read_text().strip()
        public_hex = PUBLIC_PATH.read_text().strip()
        return private_hex, public_hex

    private_key = ed25519.Ed25519PrivateKey.generate()

    private_bytes = private_key.private_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PrivateFormat.Raw,
        encryption_algorithm=serialization.NoEncryption(),
    )
    public_bytes = private_key.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )

    private_hex = private_bytes.hex()
    public_hex = public_bytes.hex()

    PRIVATE_PATH.write_text(private_hex + "\n", encoding="utf-8")
    PUBLIC_PATH.write_text(public_hex + "\n", encoding="utf-8")

    return private_hex, public_hex


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Replace an existing keypair (every installed app will reject "
             "updates signed by the old key).",
    )
    args = parser.parse_args()

    private_hex, public_hex = generate(overwrite=args.overwrite)

    print("private:", private_hex)
    print("public: ", public_hex)
    print()
    print("Set this in app/lib/services/update_service.dart:")
    print(f"  _compiledInPublicKeyHex =")
    print(f"      '{public_hex}';")
    print()
    print("Keep server/keys/private.hex out of any production repository.")