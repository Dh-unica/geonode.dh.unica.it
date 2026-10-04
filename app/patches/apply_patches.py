#!/usr/bin/env python3
"""Correzioni locali al codice di GeoNode, applicate in fase di build (Dockerfile.4.4.5).

Ogni patch sostituisce un frammento ESATTO di codice. Se il frammento non c'è (GeoNode aggiornato e codice
cambiato) la build FALLISCE: la patch va rivista, non persa in silenzio. Se GeoNode contiene già la correzione,
la build fallisce lo stesso e chiede di rimuovere la patch.

Elenco e motivazioni: app/patches/README.md
"""
import sys
from pathlib import Path

import geonode

GEONODE_DIR = Path(geonode.__file__).parent

PATCHES = [
    {
        "id": "set-styles-alt-workspace",
        "file": "geoserver/helpers.py",
        "why": "set_styles scarta gli stili alternativi nello stesso workspace dello stile di default "
               "(and invece di or): salvando uno stile, il dataset perde gli stili alternativi",
        "old": (
            "                        and alt_style.name != layer.default_style.name\n"
            "                        and alt_style.workspace != layer.default_style.workspace\n"
        ),
        "new": (
            "                        and (\n"
            "                            alt_style.name != layer.default_style.name\n"
            "                            or alt_style.workspace != layer.default_style.workspace\n"
            "                        )  # patch uni_cagliari: set-styles-alt-workspace\n"
        ),
        "expected_count": 1,  # in set_styles (GeoNode 4.4.1 e 4.4.5)
    },
]


def main():
    failed = False
    for p in PATCHES:
        path = GEONODE_DIR / p["file"]
        src = path.read_text()
        if p["new"] in src:
            print(f"PATCH {p['id']}: già applicata")
            continue
        count = src.count(p["old"])
        if count != p["expected_count"]:
            print(f"ERRORE PATCH {p['id']}: trovate {count} occorrenze invece di {p['expected_count']} in {path}.\n"
                  f"  Motivo della patch: {p['why']}\n"
                  "  Il codice di GeoNode è cambiato: verificare se il difetto è stato corretto upstream "
                  "(in quel caso rimuovere la patch) o adattarla. Vedi app/patches/README.md", file=sys.stderr)
            failed = True
            continue
        path.write_text(src.replace(p["old"], p["new"]))
        print(f"PATCH {p['id']}: applicata ({count} occorrenze) in {path}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
