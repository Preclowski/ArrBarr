import unittest
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import lint_missing_keys as lmk

class TestMissingKeys(unittest.TestCase):
    def test_flags_area_key_absent_from_catalog(self):
        # monkeypatch the catalog reader
        orig = lmk.catalog_keys_and_areas
        lmk.catalog_keys_and_areas = lambda: ({"chat.real.button"}, {"chat"})
        tmp = Path(__file__).parent / "fixtures" / "_codeprobe"
        tmp.mkdir(parents=True, exist_ok=True)
        (tmp / "A.swift").write_text('Text(k); let k: LocalizedStringKey = "chat.ghost.button"')
        (tmp / "B.swift").write_text('Image(systemName: "arrow.down.circle")')  # not an area
        try:
            bad = lmk.missing_keys(sources=tmp)
            self.assertIn("chat.ghost.button", bad)        # area key, absent -> flagged
            self.assertNotIn("arrow.down.circle", bad)     # SF symbol -> ignored
        finally:
            lmk.catalog_keys_and_areas = orig
            (tmp / "A.swift").unlink(); (tmp / "B.swift").unlink()

    def test_symbol_context_skips_area_collisions(self):
        # "person" IS a catalog area, but "person.fill" here is an SF Symbol —
        # the symbol-parameter context must suppress the false positive while
        # a genuine missing person.* key is still flagged.
        orig = lmk.catalog_keys_and_areas
        lmk.catalog_keys_and_areas = lambda: ({"person.movies.button"}, {"person"})
        tmp = Path(__file__).parent / "fixtures" / "_codeprobe"
        tmp.mkdir(parents=True, exist_ok=True)
        (tmp / "C.swift").write_text(
            'RemotePoster(fallbackSymbol: "person.fill")\n'
            'Image(systemName: "person.crop.circle")\n'
            'Text("person.ghost.label", bundle: .module)')
        try:
            bad = lmk.missing_keys(sources=tmp)
            self.assertNotIn("person.fill", bad)
            self.assertNotIn("person.crop.circle", bad)
            self.assertIn("person.ghost.label", bad)
        finally:
            lmk.catalog_keys_and_areas = orig
            (tmp / "C.swift").unlink()

if __name__ == "__main__":
    unittest.main()
