import json, unittest
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from loc_audit import audit

FIX = Path(__file__).parent / "fixtures" / "sample.xcstrings"

class TestAudit(unittest.TestCase):
    def setUp(self):
        self.report = audit(json.loads(FIX.read_text()),
                            languages=["en", "pl", "de", "es", "fr", "nl"])

    def test_detects_empty_key(self):
        self.assertIn("", self.report["empty_keys"])

    def test_detects_empty_value(self):
        self.assertIn(("queue.pauseAll.button", "de"), self.report["empty_values"])

    def test_detects_new_state(self):
        self.assertIn(("discover.noMoreCards.title", "en"), self.report["new_state"])

    def test_detects_missing(self):
        self.assertIn(("discover.noMoreCards.title", "pl"), self.report["missing"])

    def test_total_keys_excludes_nothing(self):
        self.assertEqual(self.report["total_keys"], 3)

if __name__ == "__main__":
    unittest.main()
