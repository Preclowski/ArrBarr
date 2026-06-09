import unittest
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check_mapping import validate

class TestCheck(unittest.TestCase):
    def test_flags_duplicate_new_keys(self):
        recs = [{"oldKey":"A","newKey":"queue.x.button","en":"A"},
                {"oldKey":"B","newKey":"queue.x.button","en":"B"}]
        errs = validate(recs)
        self.assertTrue(any("duplicate" in e for e in errs))

    def test_flags_bad_key_format(self):
        recs = [{"oldKey":"A","newKey":"Queue X","en":"A"}]
        errs = validate(recs)
        self.assertTrue(any("format" in e for e in errs))

    def test_flags_empty_new_key(self):
        recs = [{"oldKey":"A","newKey":"","en":"A"}]
        errs = validate(recs)
        self.assertTrue(any("empty" in e for e in errs))

    def test_clean_mapping_has_no_errors(self):
        recs = [{"oldKey":"A","newKey":"queue.pauseAll.button","en":"A"},
                {"oldKey":"B","newKey":"queue.resumeAll.button","en":"B"}]
        self.assertEqual(validate(recs), [])

if __name__ == "__main__":
    unittest.main()
