#!/usr/bin/env python3
"""Manage VexSign premium keys from the command line.

Usage:
    python keygen.py create [-n 5]          Generate n fresh keys (default 1)
    python keygen.py add VEX-XXXX-XXXX-XXXX Add a specific key manually
    python keygen.py list                   List all keys and their status
    python keygen.py disable VEX-...        App will report the key as disabled (403)
    python keygen.py enable VEX-...
    python keygen.py reset VEX-...          Make a consumed key fresh again (unbinds device)
    python keygen.py revoke VEX-...         Delete the key entirely
"""

import argparse
import secrets
import sys
import time

import db


def generate_key() -> str:
    parts = ("".join(secrets.choice(db.KEY_ALPHABET) for _ in range(4)) for _ in range(3))
    return "VEX-" + "-".join(parts)


def cmd_create(count: int) -> None:
    for _ in range(count):
        key = generate_key()
        db.add_key(key)
        print(key)


def cmd_add(key: str) -> None:
    if db.get_key(key):
        sys.exit(f"Key already exists: {key}")
    db.add_key(key)
    print(f"Added: {key}")


def cmd_list() -> None:
    with db.connect() as conn:
        rows = conn.execute(
            "SELECT api_key, used, device_uuid, disabled, created_at FROM keys ORDER BY created_at DESC"
        ).fetchall()

    if not rows:
        print("No keys. Create one with: python keygen.py create")
        return

    for row in rows:
        status = "DISABLED" if row["disabled"] else ("USED" if row["used"] else "FRESH")
        device = f" device={row['device_uuid'][:8]}…" if row["device_uuid"] else ""
        created = time.strftime("%Y-%m-%d %H:%M", time.localtime(row["created_at"]))
        print(f"{row['api_key']}  [{status}]{device}  ({created})")


def _set_flag(key: str, sql: str, verb: str) -> None:
    # Keys are stored upper-cased; normalise so `disable vex-…` (lowercase or
    # pasted with whitespace) still matches the stored key.
    key = key.strip().upper()
    with db.connect() as conn:
        cur = conn.execute(sql, (key,))
        if cur.rowcount == 0:
            sys.exit(f"No such key: {key}")
    print(f"{verb}: {key}")


def main() -> None:
    parser = argparse.ArgumentParser(description="VexSign premium key manager")
    sub = parser.add_subparsers(dest="command", required=True)

    p_create = sub.add_parser("create", help="Generate fresh keys")
    p_create.add_argument("-n", type=int, default=1, help="number of keys (default 1)")

    p_add = sub.add_parser("add", help="Add a specific key")
    p_add.add_argument("key")

    sub.add_parser("list", help="List all keys")

    for name in ("disable", "enable", "reset", "revoke"):
        p = sub.add_parser(name, help=f"{name.capitalize()} a key")
        p.add_argument("key")

    args = parser.parse_args()

    match args.command:
        case "create":
            cmd_create(max(args.n, 1))
        case "add":
            cmd_add(args.key.strip().upper())
        case "list":
            cmd_list()
        case "disable":
            _set_flag(args.key, "UPDATE keys SET disabled = 1 WHERE api_key = ?", "Disabled")
        case "enable":
            _set_flag(args.key, "UPDATE keys SET disabled = 0 WHERE api_key = ?", "Enabled")
        case "reset":
            _set_flag(args.key, "UPDATE keys SET used = 0, device_uuid = NULL WHERE api_key = ?", "Reset")
        case "revoke":
            _set_flag(args.key, "DELETE FROM keys WHERE api_key = ?", "Revoked")


if __name__ == "__main__":
    main()
