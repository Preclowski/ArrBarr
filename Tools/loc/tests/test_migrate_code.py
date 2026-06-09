import unittest
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from migrate_code import migrate_text

class TestMigrate(unittest.TestCase):
    def setUp(self):
        self.m = {"Pause all": "queue.pauseAll.button",
                  "Resume all": "queue.resumeAll.button"}

    def test_replaces_text_literal(self):
        src = 'Text("Pause all", bundle: .module)'
        self.assertEqual(migrate_text(src, self.m),
                         'Text("queue.pauseAll.button", bundle: .module)')

    def test_replaces_string_localized(self):
        src = 'String(localized: "Resume all", bundle: .module)'
        self.assertEqual(migrate_text(src, self.m),
                         'String(localized: "queue.resumeAll.button", bundle: .module)')

    def test_leaves_unrelated_strings(self):
        src = 'let id = "Pause all"  // not a localization call'
        self.assertEqual(migrate_text(src, self.m), src)

    def test_idempotent(self):
        once = migrate_text('Text("Pause all", bundle: .module)', self.m)
        twice = migrate_text(once, self.m)
        self.assertEqual(once, twice)

if __name__ == "__main__":
    unittest.main()
