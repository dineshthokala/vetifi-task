"""
Contract tests: the app and the server must agree on what valid data is.

The app is the last line of defence. If the server accepts a `g/kg` dose and the
app then reads it as `mg/kg`, the patient receives 1/1000 of the intended dose
with no warning anywhere. These tests pin the shared vocabulary so that a change
on one side without the other fails the build rather than a patient.

The Dart side of the same vocabulary lives in app/lib/models/drug.dart and is
asserted by app/test/dose_calculator_test.dart.
"""

import re
from pathlib import Path

import pytest

from server.app.validator import (
    SUPPORTED_CRI_UNITS,
    SUPPORTED_DOSE_UNITS,
    canonical_unit,
    validate_drug_entry,
)

REPO_ROOT = Path(__file__).resolve().parents[2]
DRUG_DART = REPO_ROOT / "app" / "lib" / "models" / "drug.dart"


def _dart_set_const(source: str, name: str) -> set[str]:
    """Extracts a `const Set<String> name = {'a', 'b'};` declaration."""
    match = re.search(
        r"const\s+Set<String>\s+" + name + r"\s*=\s*\{([^}]*)\}",
        source,
    )
    assert match, f"could not find {name} in drug.dart"
    return set(re.findall(r"'([^']+)'", match.group(1)))


@pytest.mark.skipif(not DRUG_DART.exists(), reason="app/ not present")
def test_unit_vocabulary_matches_app():
    """The server and the app must accept exactly the same dose units."""
    dart = DRUG_DART.read_text(encoding="utf-8")

    assert _dart_set_const(dart, "kSupportedDoseUnits") == set(SUPPORTED_DOSE_UNITS)
    assert _dart_set_const(dart, "kSupportedCriUnits") == set(SUPPORTED_CRI_UNITS)


def _valid_drug(**overrides):
    drug = {
        "id": "t001",
        "name": "Test Drug",
        "concentration": "10 mg/mL",
        "route": "IV",
        "doses": {"dog": {"min": 1, "max": 2, "unit": "mg/kg"}},
    }
    drug.update(overrides)
    return drug


def test_accepts_valid_entry():
    assert validate_drug_entry(_valid_drug()) == []


@pytest.mark.parametrize("unit", ["g/kg", "ug/kg", "mg/kg/min", "mg", "", None, "mL/hr"])
def test_rejects_uncomputable_units(unit):
    """Anything the calculator cannot convert must be refused at publish time."""
    errors = validate_drug_entry(
        _valid_drug(doses={"dog": {"min": 1, "max": 2, "unit": unit}})
    )
    assert any(e["field"] == "doses.dog.unit" for e in errors), errors


def test_canonical_unit_normalises_case_and_space():
    assert canonical_unit(" MG/KG ") == "mg/kg"
    assert canonical_unit("MCG/KG") == "mcg/kg"
    assert canonical_unit("g/kg") is None
    assert canonical_unit(None) is None


def test_rejects_unknown_top_level_field():
    """A typo such as 'concetration' would otherwise publish a valueless drug."""
    errors = validate_drug_entry(_valid_drug(concetration="10 mg/mL"))
    assert any("concetration" in e["field"] for e in errors), errors


def test_rejects_unknown_dose_field():
    errors = validate_drug_entry(
        _valid_drug(doses={"dog": {"min": 1, "max": 2, "unit": "mg/kg", "freq": "bid"}})
    )
    assert any("freq" in e["message"] for e in errors), errors


def test_rejects_inverted_range():
    errors = validate_drug_entry(
        _valid_drug(doses={"dog": {"min": 8, "max": 4, "unit": "mg/kg"}})
    )
    assert any(e["field"] == "doses.dog" for e in errors), errors


def test_rejects_zero_concentration():
    errors = validate_drug_entry(_valid_drug(concentration="0 mg/mL"))
    assert any(e["field"] == "concentration" for e in errors), errors


def test_rejects_boolean_masquerading_as_number():
    """True is an int in Python; min=True would become 1 mg/kg."""
    errors = validate_drug_entry(
        _valid_drug(doses={"dog": {"min": True, "max": 2, "unit": "mg/kg"}})
    )
    assert any(e["field"] == "doses.dog.min" for e in errors), errors


def test_cri_requires_mcg_per_kg_per_min():
    errors = validate_drug_entry(
        {
            "id": "t002",
            "name": "CRI Drug",
            "concentration": "40 mg/mL",
            "route": "IV CRI",
            "cri": {"dog": {"min": 5, "max": 10, "unit": "mg/kg/min"}},
        }
    )
    assert any(e["field"] == "cri.dog.unit" for e in errors), errors


def test_null_species_is_allowed():
    """`cat: null` means "no data for cats", which is valid to publish."""
    assert validate_drug_entry(
        _valid_drug(doses={"dog": {"min": 1, "max": 2, "unit": "mg/kg"}, "cat": None})
    ) == []


def test_rejects_nan_and_infinity():
    """Python's json parses NaN/Infinity; Dart's jsonDecode rejects them, so a
    published version containing them could never be applied by any client."""
    for bad in (float("nan"), float("inf"), float("-inf")):
        errors = validate_drug_entry(
            _valid_drug(doses={"dog": {"min": bad, "max": 2, "unit": "mg/kg"}})
        )
        assert any(e["field"] == "doses.dog.min" for e in errors), (bad, errors)
        errors = validate_drug_entry(_valid_drug(max_total_mg=bad))
        assert any(e["field"] == "max_total_mg" for e in errors), (bad, errors)


def test_rejects_bool_max_total_mg():
    """True is an int in Python; without a guard it would publish as 1 mg."""
    errors = validate_drug_entry(_valid_drug(max_total_mg=True))
    assert any(e["field"] == "max_total_mg" for e in errors), errors


def test_rejects_duplicate_species_after_normalisation():
    """The app keys doses by normalised species, so "Dog" and "dog" would
    silently overwrite each other on the client."""
    errors = validate_drug_entry(
        _valid_drug(doses={
            "Dog": {"min": 1, "max": 2, "unit": "mg/kg"},
            "dog": {"min": 3, "max": 4, "unit": "mg/kg"},
        })
    )
    assert any("normalises" in e["message"] for e in errors), errors


def test_rejects_empty_and_all_null_doses():
    """A drug with no usable dose would publish as uncalculable."""
    assert any(
        e["field"] == "doses"
        for e in validate_drug_entry(_valid_drug(doses={}))
    )
    assert any(
        e["field"] == "doses"
        for e in validate_drug_entry(
            _valid_drug(doses={"dog": None, "cat": None})
        )
    )


def test_rejects_impossible_percentage():
    """Above 100% w/v is physically impossible and always a data-entry error."""
    errors = validate_drug_entry(_valid_drug(concentration="1000%"))
    assert any(e["field"] == "concentration" for e in errors), errors
    assert validate_drug_entry(_valid_drug(concentration="100%")) == []


def test_rejects_non_ascii_digits_in_concentration():
    """Python \\d matches Unicode digits and float() parses them; Dart's \\d
    and double.tryParse are ASCII-only. Accepting them here would publish a
    concentration no client can parse."""
    errors = validate_drug_entry(_valid_drug(concentration="٥٠ mg/mL"))
    assert any(e["field"] == "concentration" for e in errors), errors