#!/usr/bin/env python3
"""Run isolated local Loco verification without putting credentials in arguments."""

import argparse
import os
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["build", "serve", "test", "fmt", "clippy"])
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--target", type=Path, required=True)
    parser.add_argument("--credentials", type=Path)
    parser.add_argument("--key-file", type=Path)
    parser.add_argument("--storage-prefix")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    state = args.state.resolve()
    target = args.target.resolve()
    if state == target or state in target.parents or target in state.parents:
        parser.error("Keep state and regenerable build output in separate directories")
    env = os.environ.copy()
    env.setdefault("CARGO_BUILD_JOBS", "2")
    env.update({
        "CARGO_TARGET_DIR": str(target),
        "CARGO_PROFILE_DEV_DEBUG": "0",
        "CARGO_PROFILE_TEST_DEBUG": "0",
        "RUST_BACKTRACE": "0",
    })
    if args.action in {"serve", "test"}:
        if not args.credentials or not args.key_file or not args.storage_prefix:
            parser.error("serve/test require --credentials, --key-file, and --storage-prefix")
        if not args.storage_prefix.startswith("local-verification/"):
            parser.error("Use a distinct local-verification/ storage prefix")
        credentials = args.credentials.resolve(strict=True)
        key_file = args.key_file.resolve(strict=True)
        if root == key_file or root in key_file.parents:
            parser.error("The unlocking key must be outside the application checkout")
        if (key_file.stat().st_mode & 0o777) not in {0o400, 0o600}:
            parser.error("The unlocking key file must have mode 0400 or 0600")
        state.mkdir(parents=True, exist_ok=True, mode=0o700)
        (state / "tenants").mkdir(exist_ok=True, mode=0o700)
        env.pop("CREDSEAL_MASTER_KEY", None)
        env.update({
            "CREDSEAL_KEY_FILE": str(key_file),
            "POSTDEPLOY_CREDENTIALS_FILE": str(credentials),
            "POSTDEPLOY_TENANT_ROOT": str(state / "tenants"),
            "DATABASE_URL": f"sqlite://{state / 'control.sqlite'}?mode=rwc",
            "POSTDEPLOY_STORAGE_PREFIX": args.storage_prefix,
            "POSTDEPLOY_LOG": "false",
        })
        if args.action == "test":
            env["POSTDEPLOY_TEST_ROOT"] = str(state / "test-runs")
    commands = {
        "build": ["cargo", "build", "--locked"],
        "serve": ["cargo", "run", "--locked", "--bin", "postdeploy-cli", "--", "start", "--environment", "test"],
        "test": ["cargo", "test", "--locked"],
        "fmt": ["cargo", "fmt", "--all", "--", "--check"],
        "clippy": ["cargo", "clippy", "--locked", "--all-targets", "--", "-D", "warnings"],
    }
    try:
        result = subprocess.run(commands[args.action], cwd=root, env=env, check=False)
    except OSError:
        print("Could not start the local verification command", file=sys.stderr)
        return 1
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
