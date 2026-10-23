#!/usr/bin/env python3
"""Offline invariants for Server2 CML rule-index extraction.

    python tests/test_extract_constraint_rules.py
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "scripts" / "cml"))

from extract_constraint_rules import (  # noqa: E402
    DEFAULT_BLOB,
    collect_rules,
)


DUAL_GOLD = (
    "Dual cannot use a Gold CPU. Pick a Platinum, or switch Socket to Single."
)
X16 = (
    "Do not edit x16 Lanes. Dual with this Performance Tier adds a GPU. "
    "Set Performance Tier to Entry, or set Socket to Single."
)


class ExtractConstraintRulesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.rules = collect_rules(DEFAULT_BLOB.read_text(encoding="utf-8"))
        cls.by_text = {rule["ruleText"]: rule for rule in cls.rules}

    def test_extracts_error_runtime_messages(self) -> None:
        self.assertGreaterEqual(len(self.rules), 10)
        self.assertIn(DUAL_GOLD, self.by_text)
        self.assertIn(X16, self.by_text)

    def test_dual_gold_flips_are_platinum_or_socket_single(self) -> None:
        rule = self.by_text[DUAL_GOLD]
        self.assertEqual("dualGold", rule["match"])
        self.assertEqual(["platinum", "socketSingle"], rule["flips"])
        self.assertEqual("Dual requires Gold quantity 0.", rule["violating"])
        self.assertIn("SocketConfiguration", rule["attributes"])

    def test_dual_workload_includes_socket_flips(self) -> None:
        rule = self.by_text[
            "Dual sockets need Workload AI or High Performance Computing. "
            "General workload needs a single socket."
        ]
        self.assertEqual("dualWorkload", rule["match"])
        self.assertIn("workloadAiHpc", rule["flips"])
        self.assertIn("workloadGeneral", rule["flips"])
        self.assertIn("socketSingle", rule["flips"])
        self.assertIn("socketDual", rule["flips"])

    def test_x16_message_is_error_not_warning(self) -> None:
        rule = self.by_text[X16]
        self.assertEqual("message", rule["kind"])
        self.assertEqual("x16Lanes", rule["match"])
        self.assertEqual(["socketSingle", "tierEntry"], rule["flips"])

    def test_skips_warning_and_info_messages(self) -> None:
        texts = " ".join(rule["ruleText"] for rule in self.rules)
        self.assertNotIn("Warning", texts)
        for rule in self.rules:
            self.assertFalse(rule["ruleText"].lower().startswith("info"))

    def test_writes_json_index(self) -> None:
        import extract_constraint_rules as ext

        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "rule-index.json"
            sys.argv = [
                "extract_constraint_rules.py",
                "--out",
                str(out),
                "--skip-apex",
            ]
            self.assertEqual(0, ext.main())
            payload = json.loads(out.read_text(encoding="utf-8"))
            self.assertEqual("Server2", payload["model"])
            self.assertEqual(len(self.rules), len(payload["rules"]))


if __name__ == "__main__":
    raise SystemExit(unittest.main())
