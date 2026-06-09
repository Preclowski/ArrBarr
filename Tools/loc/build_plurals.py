#!/usr/bin/env python3
"""Helper to construct xcstrings plural-variation stringUnits."""

def make_plural_unit(forms):
    """forms: {category: value}. Returns a localization unit with variations.plural."""
    return {"variations": {"plural": {
        cat: {"stringUnit": {"state": "translated", "value": val}}
        for cat, val in forms.items()}}}
