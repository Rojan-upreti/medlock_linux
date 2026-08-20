#!/usr/bin/env python3
"""Create the first owner user in the MedLock database. Never prints the password."""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
os.environ.setdefault("PROJECT_DIR", str(ROOT))
sys.path.insert(0, str(ROOT))

from app.db import User, get_engine, get_session  # noqa: E402
from app.services.auth import create_user  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description="Create MedLock owner account")
    parser.add_argument("--username")
    parser.add_argument("--password")
    parser.add_argument("--role", default="owner", choices=("owner", "chat"))
    parser.add_argument("--check", action="store_true", help="Exit 0 if an owner exists")
    args = parser.parse_args()
    get_engine()
    db = get_session()
    try:
        existing = db.query(User).filter(User.role == "owner").first()
        if args.check:
            if existing:
                print(existing.username)
                return 0
            print("missing")
            return 1
        if not args.username or not args.password:
            print("--username and --password are required", file=sys.stderr)
            return 2
        if args.role == "owner" and existing:
            print(f"owner exists: {existing.username}")
            return 0
        user = create_user(db, args.username, args.password, args.role)
        print(f"created {user.role}: {user.username}")
        return 0
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    finally:
        db.close()


if __name__ == "__main__":
    raise SystemExit(main())
