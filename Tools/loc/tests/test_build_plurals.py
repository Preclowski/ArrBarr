import unittest
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from build_plurals import make_plural_unit

class TestPlural(unittest.TestCase):
    def test_polish_has_four_categories(self):
        forms = {"one": "%lld dzień", "few": "%lld dni", "many": "%lld dni", "other": "%lld dnia"}
        unit = make_plural_unit(forms)
        cats = unit["variations"]["plural"]
        self.assertEqual(set(cats), {"one", "few", "many", "other"})
        self.assertEqual(cats["few"]["stringUnit"]["value"], "%lld dni")

    def test_english_two_categories(self):
        unit = make_plural_unit({"one": "%lld day", "other": "%lld days"})
        self.assertEqual(set(unit["variations"]["plural"]), {"one", "other"})

if __name__ == "__main__":
    unittest.main()
