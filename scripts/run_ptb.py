#!/usr/bin/env python3
"""
Utility runner for PTB snippets.

Reads a PTB file, strips comments, expands any environment variables, tokenizes
the commands with shlex, and forwards the resulting arguments to
`sui client ptb`. Additional CLI options supplied after `--` are passed through
unchanged (for example `--preview` or `--dry-run`).
"""
from __future__ import annotations

import argparse
import os
import pathlib
import re
import shlex
import subprocess
import sys


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run a PTB script using `sui client ptb`.",
    )
    parser.add_argument(
        "ptb_path",
        type=pathlib.Path,
        help="Path to the .ptb file to execute.",
    )
    parser.add_argument(
        "extra",
        nargs=argparse.REMAINDER,
        help="Optional extra arguments forwarded to `sui client ptb` (prefix with --).",
    )
    return parser.parse_args()


ENV_VAR_PATTERN = re.compile(r"\$(\w+)|\$\{([^}]+)\}")


def expand_env(token: str) -> str:
    def replace(match: re.Match[str]) -> str:
        name = match.group(1) or match.group(2)
        if name not in os.environ:
            print(f"Missing required environment variable: {name}", file=sys.stderr)
            raise SystemExit(1)
        return os.environ[name]

    return ENV_VAR_PATTERN.sub(replace, token)


def main() -> int:
    args = parse_args()
    ptb_source = args.ptb_path.read_text()
    tokens = [expand_env(tok) for tok in shlex.split(ptb_source, comments=True)]

    if not tokens:
        print(f"No PTB commands found in {args.ptb_path}", file=sys.stderr)
        return 1

    cmd = ["sui", "client", "ptb", *args.extra, *tokens]
    print("Executing:", shlex.join(cmd))

    try:
        subprocess.run(cmd, check=True)
    except subprocess.CalledProcessError as exc:
        return exc.returncode
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
