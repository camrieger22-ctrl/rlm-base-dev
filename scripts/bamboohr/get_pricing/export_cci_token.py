#!/usr/bin/env python3
"""Print shell exports for SF_ACCESS_TOKEN + SF_INSTANCE_URL from a CCI org.

Usage:
  eval "$(python scripts/bamboohr/get_pricing/export_cci_token.py --org master-demo)"
"""

from __future__ import annotations

import argparse
import shlex
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from auth import resolve_creds  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--org", default="master-demo")
    # Force CCI path even if SF_* already set in the parent shell.
    parser.add_argument(
        "--force-cci",
        action="store_true",
        help="Ignore existing SF_* env and load the CCI alias",
    )
    args = parser.parse_args()
    if args.force_cci:
        import os

        for key in (
            "SF_ACCESS_TOKEN",
            "SF_INSTANCE_URL",
            "SF_CLIENT_ID",
            "SF_USERNAME",
            "SF_PRIVATE_KEY",
            "SF_PRIVATE_KEY_PATH",
        ):
            os.environ.pop(key, None)
    creds = resolve_creds(args.org)
    print(f"export SF_ACCESS_TOKEN={shlex.quote(creds.access_token)}")
    print(f"export SF_INSTANCE_URL={shlex.quote(creds.instance_url)}")
    print(f"# authMode={creds.mode} label={creds.label}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
