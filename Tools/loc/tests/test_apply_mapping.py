import unittest
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from apply_mapping import rebuild

class TestApply(unittest.TestCase):
    def setUp(self):
        self.old = {
            "sourceLanguage": "en", "version": "1.1",
            "strings": {
                "": {},
                "Pause all": {
                    "localizations": {
                        "pl": {"stringUnit": {"state": "translated", "value": "Wstrzymaj wszystko"}},
                        "de": {"stringUnit": {"state": "translated", "value": "Alle pausieren"}},
                    }
                },
            },
        }
        self.mapping = [
            {"oldKey": "Pause all", "newKey": "queue.pauseAll.button",
             "en": "Pause all", "comment": "Pause-all button"},
        ]
        self.new = rebuild(self.old, self.mapping, keep_langs=["pl"])

    def test_empty_key_dropped(self):
        self.assertNotIn("", self.new["strings"])

    def test_dotted_key_present(self):
        self.assertIn("queue.pauseAll.button", self.new["strings"])

    def test_en_materialized(self):
        unit = self.new["strings"]["queue.pauseAll.button"]["localizations"]["en"]["stringUnit"]
        self.assertEqual(unit["value"], "Pause all")
        self.assertEqual(unit["state"], "translated")

    def test_comment_written(self):
        self.assertEqual(self.new["strings"]["queue.pauseAll.button"]["comment"], "Pause-all button")

    def test_pl_carried_over(self):
        unit = self.new["strings"]["queue.pauseAll.button"]["localizations"]["pl"]["stringUnit"]
        self.assertEqual(unit["value"], "Wstrzymaj wszystko")

    def test_de_dropped(self):
        self.assertNotIn("de", self.new["strings"]["queue.pauseAll.button"]["localizations"])

if __name__ == "__main__":
    unittest.main()
