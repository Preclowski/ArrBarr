import unittest
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from lint_english_literals import offending_literals

class TestLint(unittest.TestCase):
    def test_flags_english_literal(self):
        src = 'Text("Pause all", bundle: .module)'
        self.assertEqual(offending_literals(src), ["Pause all"])

    def test_accepts_dotted_key(self):
        src = 'Text("queue.pauseAll.button", bundle: .module)'
        self.assertEqual(offending_literals(src), [])

    def test_ignores_format_specifier_only(self):
        src = 'Text("\\(count)", bundle: .module)'
        self.assertEqual(offending_literals(src), [])

if __name__ == "__main__":
    unittest.main()
