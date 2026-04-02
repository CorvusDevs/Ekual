#!/usr/bin/env python3
"""
Ekual License Key Generator

Usage:
  # One-time: generate keypair
  python license_keygen.py --generate-keys

  # Ongoing: sign a license for a customer
  python license_keygen.py --sign --email user@example.com

  # Verify a license key (for testing)
  python license_keygen.py --verify "BASE64PAYLOAD.BASE64SIGNATURE"
"""

import argparse
import base64
import json
import sys
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
)
from cryptography.hazmat.primitives.serialization import (
    Encoding,
    NoEncryption,
    PrivateFormat,
    PublicFormat,
    load_pem_private_key,
    load_pem_public_key,
)

KEYS_DIR = Path(__file__).parent / ".keys"
PRIVATE_KEY_PATH = KEYS_DIR / "private.pem"
PUBLIC_KEY_PATH = KEYS_DIR / "public.pem"

PRODUCT = "ekual"


def generate_keys():
    """Generate Ed25519 keypair and save to .keys/ directory."""
    KEYS_DIR.mkdir(exist_ok=True)

    if PRIVATE_KEY_PATH.exists():
        print(f"ERROR: {PRIVATE_KEY_PATH} already exists. Remove it first to regenerate.")
        sys.exit(1)

    private_key = Ed25519PrivateKey.generate()
    public_key = private_key.public_key()

    PRIVATE_KEY_PATH.write_bytes(
        private_key.private_bytes(Encoding.PEM, PrivateFormat.PKCS8, NoEncryption())
    )

    PUBLIC_KEY_PATH.write_bytes(
        public_key.public_bytes(Encoding.PEM, PublicFormat.SubjectPublicKeyInfo)
    )

    raw_public = public_key.public_bytes(Encoding.Raw, PublicFormat.Raw)
    b64 = base64.b64encode(raw_public).decode()

    print(f"Keys saved to {KEYS_DIR}/")
    print(f"\nEmbed this in LicenseManager.swift:")
    print(f'  private static let publicKeyBase64 = "{b64}"')


def sign_license(email):
    """Create a signed license key for the given email."""
    private_key = load_pem_private_key(PRIVATE_KEY_PATH.read_bytes(), password=None)

    payload = json.dumps(
        {"email": email, "product": PRODUCT},
        separators=(",", ":"),
        sort_keys=True,
    ).encode()

    signature = private_key.sign(payload)

    payload_b64 = base64.b64encode(payload).decode()
    signature_b64 = base64.b64encode(signature).decode()

    return f"{payload_b64}.{signature_b64}"


def verify_license(license_key):
    """Verify a license key against the public key."""
    public_key = load_pem_public_key(PUBLIC_KEY_PATH.read_bytes())

    parts = license_key.split(".", 1)
    if len(parts) != 2:
        return False

    try:
        payload = base64.b64decode(parts[0])
        signature = base64.b64decode(parts[1])
        public_key.verify(signature, payload)
        return True
    except Exception:
        return False


def main():
    parser = argparse.ArgumentParser(description="Ekual License Key Tool")
    parser.add_argument("--generate-keys", action="store_true", help="Generate Ed25519 keypair")
    parser.add_argument("--sign", action="store_true", help="Sign a license key")
    parser.add_argument("--email", type=str, help="Customer email for --sign")
    parser.add_argument("--verify", type=str, help="Verify a license key string")
    args = parser.parse_args()

    if args.generate_keys:
        generate_keys()
    elif args.sign:
        if not args.email:
            print("ERROR: --email is required with --sign")
            sys.exit(1)
        key = sign_license(args.email)
        print(f"License key for {args.email}:")
        print(key)
    elif args.verify:
        valid = verify_license(args.verify)
        print(f"Valid: {valid}")
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
