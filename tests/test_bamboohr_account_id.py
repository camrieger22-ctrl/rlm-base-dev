#!/usr/bin/env python3
"""Offline tests: Salesforce Id copy-paste sanitizer for Licenses pin."""

from __future__ import annotations

import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GP = os.path.join(REPO_ROOT, "scripts", "bamboohr", "get_pricing")
sys.path.insert(0, GP)

from account_console import normalize_salesforce_id  # noqa: E402

RESULTS: list[tuple[str, bool]] = []


def check(name: str, condition: bool) -> None:
    RESULTS.append((name, bool(condition)))
    print(f"  [{'PASS' if condition else 'FAIL'}] {name}")


def main() -> int:
    print("\nnormalize salesforce id")
    aid = "001gL00001irUhdQAE"
    check("plain id", normalize_salesforce_id(aid) == aid)
    check("trailing period", normalize_salesforce_id(aid + ".") == aid)
    check("sentence punctuation", normalize_salesforce_id(aid + ").") == aid)
    check("quoted", normalize_salesforce_id("'" + aid + "'") == aid)
    check("whitespace", normalize_salesforce_id("  " + aid + "  ") == aid)
    check("empty", normalize_salesforce_id("   ") is None)
    check("none", normalize_salesforce_id(None) is None)
    passed = sum(1 for _, ok in RESULTS if ok)
    print(f"\n{passed}/{len(RESULTS)} passed")
    return 0 if passed == len(RESULTS) else 1


if __name__ == "__main__":
    raise SystemExit(main())
