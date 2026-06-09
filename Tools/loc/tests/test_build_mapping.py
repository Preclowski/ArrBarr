import unittest
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from build_mapping import slug, infer_role, suggest_key

class TestMapping(unittest.TestCase):
    def test_slug_camelcases_first_words(self):
        self.assertEqual(slug("Pause all downloads"), "pauseAllDownloads")

    def test_slug_truncates_long_text(self):
        s = slug("This is a very long sentence that should be truncated cleanly")
        self.assertLessEqual(s.count(" "), 0)
        self.assertTrue(len(s) <= 40)

    def test_infer_role_tooltip_for_sentence(self):
        self.assertEqual(infer_role("Pauses every active download."), "tooltip")

    def test_infer_role_button_for_short_imperative(self):
        self.assertEqual(infer_role("Pause all"), "button")

    def test_suggest_key_uses_area(self):
        self.assertTrue(suggest_key("queue", "Pause all").startswith("queue."))

if __name__ == "__main__":
    unittest.main()
