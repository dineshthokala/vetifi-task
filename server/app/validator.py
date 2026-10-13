"""
Validation rules for drug entries and dataset updates.

These rules are deliberately kept byte-for-byte equivalent to the ones in
app/lib/models/drug.dart. The unit vocabulary in particular must match, or the
app would accept something the server considers valid but cannot compute with
(a g/kg entry computed as mg/kg is a 1000x underdose).

`tests/test_contract.py` asserts the two vocabularies agree, so drift is a test
failure rather than a production surprise.
"""

import math
import re
from typing import Any

# Must match kSupportedDoseUnits / kSupportedCriUnits in app/lib/models/drug.dart.
SUPPORTED_DOSE_UNITS = ("mg/kg", "mcg/kg")
SUPPORTED_CRI_UNITS = ("mcg/kg/min",)

# Fields a drug entry may contain. Anything else is a typo or a schema change
# that this server version does not understand, so it is rejected rather than
# silently ignored.
ALLOWED_DRUG_FIELDS = frozenset(
    {"id", "name", "concentration", "route", "max_total_mg", "doses", "cri"}
)

ALLOWED_DOSE_FIELDS = frozenset({"min", "max", "unit"})


class ValidationError(Exception):
    def __init__(self, errors: list[dict[str, Any]]):
        super().__init__(str(errors))
        self.errors = errors


def parse_concentration(raw: str) -> float | None:
    """
    Parses concentration strings like '50 mg/mL' or '10%' into mg/mL.
    Returns float mg/mL if valid, None otherwise.

    The digit classes are ASCII-only on purpose: the app's Dart parser uses
    ASCII `\\d` and `double.tryParse`, so a string Python would accept with
    Unicode digits (e.g. Arabic-Indic) is one the app cannot parse. Accepting
    it here would publish a drug no client can calculate with.

    Percentages above 100 are physically impossible (>100% w/v) and always a
    data-entry error, so they are rejected rather than scaled into mg/mL.
    """
    if not isinstance(raw, str):
        return None
    trimmed = raw.strip()
    if not trimmed:
        return None

    # Percentage: 10% = 10g / 100mL = 100 mg/mL
    pct_match = re.match(r"^(\d+\.?\d*)\s*%$", trimmed, re.ASCII)
    if pct_match:
        try:
            val = float(pct_match.group(1))
            if 0 < val <= 100:
                return val * 10.0
        except ValueError:
            return None
        return None

    # mg/mL format
    mg_match = re.match(r"^(\d+\.?\d*)\s*mg\s*/\s*m[lL]$", trimmed, re.IGNORECASE | re.ASCII)
    if mg_match:
        try:
            val = float(mg_match.group(1))
            if val > 0:
                return val
        except ValueError:
            return None
        return None

    return None


def _is_valid_number(value: Any) -> bool:
    """
    A JSON number the app can actually consume: a real, finite number.

    Bools are excluded even though Python subclasses bool from int: True would
    otherwise pass as 1 mg/kg. NaN and Infinity are excluded because Python's
    json module parses the non-standard literals while Dart's jsonDecode
    rejects them, so accepting them here publishes a version no client can
    apply -- and published versions are immutable.
    """
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value)
    )


def normalize_species(raw: str) -> str:
    lower = raw.strip().lower()
    if lower in ("dog", "canine"):
        return "dog"
    if lower in ("cat", "feline"):
        return "cat"
    return lower


def canonical_unit(raw: Any) -> str | None:
    """
    Normalises a dose unit for comparison, matching canonicalDoseUnit() in
    app/lib/models/drug.dart.

    Returns None when the unit is not one the calculator can work with, so the
    caller reports a precise field error instead of accepting a unit that would
    later be silently misinterpreted.
    """
    if not isinstance(raw, str):
        return None
    normalised = raw.strip().lower()
    if normalised in SUPPORTED_DOSE_UNITS or normalised in SUPPORTED_CRI_UNITS:
        return normalised
    return None


def validate_drug_entry(drug: dict[str, Any]) -> list[dict[str, str]]:
    """
    Validates a single drug entry dictionary.
    Returns list of error dicts: [{"drug_id": id, "field": field, "message": msg}]
    """
    errors: list[dict[str, str]] = []
    drug_id = drug.get("id") or "UNKNOWN"

    # Reject unknown fields. A typo such as "concetration" would otherwise leave
    # the drug with no concentration at all and sail through publishing.
    unknown_fields = sorted(set(drug.keys()) - ALLOWED_DRUG_FIELDS)
    if unknown_fields:
        errors.append({
            "drug_id": drug_id,
            "field": ",".join(unknown_fields),
            "message": f"Unknown field(s) not permitted in schema 2: "
                       f"{', '.join(unknown_fields)}",
        })

    # ID validation
    if not drug.get("id") or not isinstance(drug.get("id"), str) or not drug["id"].strip():
        errors.append({"drug_id": drug_id, "field": "id", "message": "Drug ID must be a non-empty string"})

    # Name validation
    name = drug.get("name")
    if not name or not isinstance(name, str) or not name.strip():
        errors.append({"drug_id": drug_id, "field": "name", "message": "Drug name must be a non-empty string"})

    # Concentration validation
    raw_conc = drug.get("concentration")
    if not raw_conc or not isinstance(raw_conc, str):
        errors.append({"drug_id": drug_id, "field": "concentration", "message": "Concentration is required and must be a string"})
    else:
        parsed_conc = parse_concentration(raw_conc)
        if parsed_conc is None:
            errors.append({
                "drug_id": drug_id,
                "field": "concentration",
                "message": f"Invalid concentration '{raw_conc}': must be 'X mg/mL' or 'X%' "
                           f"with ASCII digits, value > 0 and percentage <= 100"
            })

    # Route validation
    route = drug.get("route")
    if not route or not isinstance(route, str) or not route.strip():
        errors.append({"drug_id": drug_id, "field": "route", "message": "Route must be a non-empty string"})

    # Max total mg validation (optional)
    if "max_total_mg" in drug and drug["max_total_mg"] is not None:
        max_total = drug["max_total_mg"]
        if not _is_valid_number(max_total) or max_total <= 0:
            errors.append({
                "drug_id": drug_id,
                "field": "max_total_mg",
                "message": f"max_total_mg must be a positive finite number, got {max_total}"
            })

    doses = drug.get("doses")
    cri = drug.get("cri")

    if doses is None and cri is None:
        errors.append({"drug_id": drug_id, "field": "doses", "message": "Drug must have either 'doses' or 'cri' specified"})

    # Validate standard doses
    if doses is not None:
        if not isinstance(doses, dict):
            errors.append({"drug_id": drug_id, "field": "doses", "message": "'doses' must be a JSON object"})
        else:
            has_at_least_one_dose = False
            seen_species: set[str] = set()
            for species_key, dose_spec in doses.items():
                if dose_spec is None:
                    continue  # e.g., cat: null is acceptable (meaning no dose for this species)

                has_at_least_one_dose = True
                norm_species = normalize_species(species_key)

                # Two keys normalising to one species ("Dog" and "dog", "dog"
                # and "canine") would silently overwrite each other on the
                # client, which keys by normalised species. Refuse the
                # ambiguity at publish time instead of letting the last one win.
                if norm_species in seen_species:
                    errors.append({
                        "drug_id": drug_id,
                        "field": f"doses.{species_key}",
                        "message": f"Species '{species_key}' normalises to '{norm_species}', "
                                   f"which is already defined for this drug"
                    })
                seen_species.add(norm_species)

                if not isinstance(dose_spec, dict):
                    errors.append({
                        "drug_id": drug_id,
                        "field": f"doses.{species_key}",
                        "message": f"Dose spec for {species_key} must be an object or null"
                    })
                    continue

                unknown = sorted(set(dose_spec.keys()) - ALLOWED_DOSE_FIELDS)
                if unknown:
                    errors.append({
                        "drug_id": drug_id,
                        "field": f"doses.{species_key}",
                        "message": f"Unknown field(s): {', '.join(unknown)}"
                    })

                min_val = dose_spec.get("min")
                max_val = dose_spec.get("max")
                unit = canonical_unit(dose_spec.get("unit"))

                if min_val is None or not _is_valid_number(min_val) or min_val <= 0:
                    errors.append({
                        "drug_id": drug_id,
                        "field": f"doses.{species_key}.min",
                        "message": f"Minimum dose for {species_key} must be a positive finite number"
                    })
                if max_val is None or not _is_valid_number(max_val) or max_val <= 0:
                    errors.append({
                        "drug_id": drug_id,
                        "field": f"doses.{species_key}.max",
                        "message": f"Maximum dose for {species_key} must be a positive finite number"
                    })

                if (
                    _is_valid_number(min_val)
                    and _is_valid_number(max_val)
                    and min_val > max_val
                ):
                    errors.append({
                        "drug_id": drug_id,
                        "field": f"doses.{species_key}",
                        "message": f"Minimum dose ({min_val}) cannot exceed maximum dose ({max_val})"
                    })

                if unit is None or unit not in SUPPORTED_DOSE_UNITS:
                    errors.append({
                        "drug_id": drug_id,
                        "field": f"doses.{species_key}.unit",
                        "message": f"Dose unit must be one of "
                                   f"{', '.join(SUPPORTED_DOSE_UNITS)}, got "
                                   f"{dose_spec.get('unit')!r}. An unrecognised "
                                   f"unit cannot be calculated safely.",
                    })

            # 'doses' present but empty, or every entry null: the drug carries
            # no usable dose and would publish as uncalculable.
            if not has_at_least_one_dose:
                errors.append({
                    "drug_id": drug_id,
                    "field": "doses",
                    "message": "'doses' must contain at least one usable species entry (use null only for species with no dose)",
                })

    # Validate CRI doses
    if cri is not None:
        if not isinstance(cri, dict):
            errors.append({"drug_id": drug_id, "field": "cri", "message": "'cri' must be a JSON object"})
        else:
            has_at_least_one_cri = False
            seen_cri_species: set[str] = set()
            for species_key, cri_spec in cri.items():
                if cri_spec is None:
                    continue
                has_at_least_one_cri = True
                norm_species = normalize_species(species_key)
                if norm_species in seen_cri_species:
                    errors.append({
                        "drug_id": drug_id,
                        "field": f"cri.{species_key}",
                        "message": f"Species '{species_key}' normalises to '{norm_species}', "
                                   f"which is already defined for this drug"
                    })
                seen_cri_species.add(norm_species)
                if not isinstance(cri_spec, dict):
                    errors.append({
                        "drug_id": drug_id,
                        "field": f"cri.{species_key}",
                        "message": f"CRI dose spec for {species_key} must be an object or null"
                    })
                    continue

                unknown = sorted(set(cri_spec.keys()) - ALLOWED_DOSE_FIELDS)
                if unknown:
                    errors.append({
                        "drug_id": drug_id,
                        "field": f"cri.{species_key}",
                        "message": f"Unknown field(s): {', '.join(unknown)}"
                    })

                min_val = cri_spec.get("min")
                max_val = cri_spec.get("max")
                unit = canonical_unit(cri_spec.get("unit"))

                if min_val is None or not _is_valid_number(min_val) or min_val <= 0:
                    errors.append({
                        "drug_id": drug_id,
                        "field": f"cri.{species_key}.min",
                        "message": f"CRI min for {species_key} must be a positive finite number"
                    })
                if max_val is None or not _is_valid_number(max_val) or max_val <= 0:
                    errors.append({
                        "drug_id": drug_id,
                        "field": f"cri.{species_key}.max",
                        "message": f"CRI max for {species_key} must be a positive finite number"
                    })
                if (
                    _is_valid_number(min_val)
                    and _is_valid_number(max_val)
                    and min_val > max_val
                ):
                    errors.append({
                        "drug_id": drug_id,
                        "field": f"cri.{species_key}",
                        "message": f"CRI minimum ({min_val}) cannot exceed maximum ({max_val})"
                    })
                if unit not in SUPPORTED_CRI_UNITS:
                    errors.append({
                        "drug_id": drug_id,
                        "field": f"cri.{species_key}.unit",
                        "message": f"CRI unit must be one of "
                                   f"{', '.join(SUPPORTED_CRI_UNITS)}, got "
                                   f"{cri_spec.get('unit')!r}",
                    })

            if not has_at_least_one_cri:
                errors.append({
                    "drug_id": drug_id,
                    "field": "cri",
                    "message": "'cri' must contain at least one usable species entry",
                })

    return errors


def parse_version_number(v: str) -> int:
    m = re.match(r"^v?(\d+)$", v.strip(), re.IGNORECASE)
    if not m:
        raise ValueError(f"Invalid version string '{v}'")
    return int(m.group(1))
