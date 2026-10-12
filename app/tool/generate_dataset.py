"""
Generates 50,000 realistic veterinary drug entries for search benchmark (Part B).
"""

import itertools
import json
import random
from pathlib import Path

PREFIXES = [
    "Amoxi", "Cepha", "Enro", "Meloxi", "Predni", "Dexa", "Ketopro", "Marbo",
    "Clavula", "Iver", "Fipron", "Oxytetra", "Fenben", "Metro", "Genta", "Sulfa",
    "Trimet", "Florfen", "Carpro", "Bupre", "Tramad", "Gaba", "Apo", "Ceren",
    "Conven", "Bravecto", "Nexgard", "Simparica", "Credelio", "Atipo", "Medeto",
    "Xyla", "Propof", "Alfax", "Butorph", "Aceprom", "Fentan", "Hydromorph",
    "Midazol", "Diazepam", "Phenobarb", "Levetira", "Pimoben", "Benazep",
    "Enalapr", "Furosem", "Torasem", "Spironol", "Amlodip", "Sildenafil",
    "Omepraz", "Pantopraz", "Famotid", "Maropit", "Ondanset", "Metoclo",
    "Sucralf", "Mirtazap", "Capromor", "Cyclospor", "Tacrolim", "Oclacit",
    "Lokivet", "Isoflur", "Sevoflur", "Lidocain", "Bupivac", "Ropivac",
]

STEMS = [
    "cillin", "lexin", "floxacin", "cam", "nisone", "methasone", "profen", "boflox",
    "nate", "mectin", "nil", "cycline", "dazole", "micin", "diazine", "prim",
    "fenicol", "vet", "nor", "dol", "pentin", "quel", "ia", "gard",
    "zole", "pame", "tomidine", "azine", "fol", "alone", "phanol", "promazine",
    "nyl", "phone", "am", "pam", "bital", "cetam", "dan", "pril",
    "semide", "mide", "lactone", "pine", "fil", "zole", "tidine", "tant",
    "setron", "pramide", "fate", "pine", "lin", "sporin", "mus", "tinib",
    "mab", "rane", "caine", "vacaine",
]

MODIFIERS = [
    "", " Forte", " Plus", " Depot", " Oral", " Injectable", " XR", " LA",
    " Solution", " Drops", " Suspension", " Vet", " Care", " Max",
]

ROUTES = ["IV", "IM", "SC", "PO", "Topical"]
UNITS = ["mg/kg", "mcg/kg"]
CONCENTRATIONS = [
    "1 mg/mL", "2 mg/mL", "5 mg/mL", "10 mg/mL", "20 mg/mL", "25 mg/mL",
    "40 mg/mL", "50 mg/mL", "100 mg/mL", "200 mg/mL", "250 mg/mL", "500 mg/mL",
    "5%", "10%", "20%"
]


def generate_50k_drugs(output_path: Path):
    random.seed(42)  # Deterministic generation
    drugs = []

    # Generate unique drug names
    combinations = list(itertools.product(PREFIXES, STEMS, MODIFIERS))
    random.shuffle(combinations)

    print(f"Total possible name combinations: {len(combinations)}")
    count = min(50000, len(combinations))

    for i in range(count):
        prefix, stem, modifier = combinations[i]
        name = f"{prefix}{stem}{modifier}".strip()
        drug_id = f"gen_{i+1:05d}"
        conc = random.choice(CONCENTRATIONS)
        route = random.choice(ROUTES)

        dog_min = round(random.uniform(0.1, 15.0), 2)
        dog_max = round(dog_min * random.uniform(1.2, 2.5), 2)

        cat_has_dose = random.random() > 0.15  # 15% missing cat dose
        if cat_has_dose:
            cat_min = round(dog_min * random.uniform(0.5, 1.0), 2)
            cat_max = round(cat_min * random.uniform(1.2, 2.0), 2)
            cat_dose = {"min": cat_min, "max": cat_max, "unit": "mg/kg"}
        else:
            cat_dose = None

        drug_entry = {
            "id": drug_id,
            "name": name,
            "concentration": conc,
            "route": route,
            "doses": {
                "dog": {"min": dog_min, "max": dog_max, "unit": "mg/kg"},
                "cat": cat_dose,
            }
        }
        drugs.append(drug_entry)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(drugs, f, indent=2)

    print(f"Successfully generated {len(drugs)} drugs to {output_path}")


if __name__ == "__main__":
    out_file = Path(__file__).resolve().parent.parent / "assets" / "data" / "generated_50k_drugs.json"
    generate_50k_drugs(out_file)
