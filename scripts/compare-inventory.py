#!/usr/bin/env python3
"""Confronta due inventari prodotti da scripts/inventory.sh (cartelle estratte) secondo il PIANO §5.5.

    scripts/compare-inventory.py <inventario-A> <inventario-B> [--only manifest]

Esclusioni previste dal piano (dati "vivi" che cambiano con il solo uso del sito):
- tabelle monitoring_*, django_session, django_celery_* (conteggi riportati come informazione, non KO);
- file worker@*.state di Celery negli statics;
- per le cartelle si confrontano solo tipo e percorso (dimensione e mtime dipendono dalla storia del filesystem).
Esce con 0 se tutti i controlli sono OK, 1 altrimenti.
"""
import fnmatch
import sys
from pathlib import Path

LIVE_TABLES = ("public.monitoring_*", "public.django_session", "public.django_celery_*")
LIVE_FILES = ("worker@*.state",)
# File della data dir che lo script di avvio di GeoServer riscrive a ogni avvio (aggiunge spazi finali, salva .orig,
# incrementa updateSequence). Verificato il 2026-10-04: nessuna differenza di configurazione. Riportati come info.
GS_REWRITTEN_AT_START = (
    "global.xml", "global.xml.orig", "notifier/notifier.xml", "geofence/geofence-datasource-ovr.properties",
    "security/filter/geonode-oauth2/config.xml", "security/filter/geonode-oauth2/config.xml.orig",
    "security/role/geonode REST role service/config.xml", "security/role/geonode REST role service/config.xml.orig",
)


def read_tsv(path):
    return [line.rstrip("\n").split("\t") for line in path.read_text().splitlines() if line.strip()]


def compare_rowcounts(a, b, name):
    ra, rb = dict(read_tsv(a / name)), dict(read_tsv(b / name))
    ko, live = [], []
    for table in sorted(set(ra) | set(rb)):
        va, vb = ra.get(table), rb.get(table)
        if va == vb:
            continue
        if any(fnmatch.fnmatch(table, p) for p in LIVE_TABLES):
            live.append(f"{table}: {va} -> {vb}")
        else:
            ko.append(f"{table}: {va} -> {vb}")
    return ko, live


def manifest(path):
    entries = {}
    for row in read_tsv(path):
        kind, size, mtime, rel = row[0], row[1], row[2], row[3]
        if any(fnmatch.fnmatch(Path(rel).name, p) for p in LIVE_FILES):
            continue
        entries[rel] = (kind,) if kind == "d" else (kind, size, mtime)
    return entries


def compare_manifest(a, b, name):
    ma, mb = manifest(a / name), manifest(b / name)
    ko = [f"solo in A: {p}" for p in sorted(set(ma) - set(mb))]
    ko += [f"solo in B: {p}" for p in sorted(set(mb) - set(ma))]
    changed = [p for p in sorted(set(ma) & set(mb)) if ma[p] != mb[p]]
    rewritten = [p for p in changed if name.startswith("31-") and p in GS_REWRITTEN_AT_START]
    ko += [f"diverso: {p} {ma[p]} -> {mb[p]}" for p in changed if p not in rewritten]
    info = [f"{len(ma)} voci confrontate"] + ([f"{len(rewritten)} file riscritti all'avvio di GeoServer"] if rewritten else [])
    return ko, info


def compare_exact(a, b, name):
    ok = (a / name).read_text() == (b / name).read_text()
    return ([] if ok else [f"{name} diverso"]), []


CHECKS = {
    "manifest": [
        ("statics: manifest file", compare_manifest, "30-manifest-statics.tsv"),
        ("gsdatadir: manifest file", compare_manifest, "31-manifest-gsdatadir.tsv"),
    ],
    "all": [
        ("geonode: righe per tabella", compare_rowcounts, "10-rowcount-geonode.tsv"),
        ("geonode_data: righe per tabella", compare_rowcounts, "10-rowcount-geonode_data.tsv"),
        ("geonode: migrazioni", compare_exact, "12-migrations-geonode.tsv"),
        ("geonode_data: migrazioni", compare_exact, "12-migrations-geonode_data.tsv"),
        ("estensioni geonode", compare_exact, "11-extensions-geonode.tsv"),
        ("estensioni geonode_data", compare_exact, "11-extensions-geonode_data.tsv"),
        ("risorse per tipo", compare_exact, "13-resources-by-type.tsv"),
        ("utenti, gruppi, permessi", compare_exact, "14-people-perms.tsv"),
        ("GeoServer REST: workspace, layer, stili", compare_exact, "20-geoserver-rest.tsv"),
        ("geonode_init.lock", compare_exact, "32-geonode_init.lock"),
        ("geoserver_init.lock", compare_exact, "33-geoserver_init.lock"),
    ],
}


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    a, b = Path(sys.argv[1]), Path(sys.argv[2])
    only = sys.argv[4] if len(sys.argv) > 4 and sys.argv[3] == "--only" else None
    checks = CHECKS["manifest"] if only == "manifest" else CHECKS["all"] + CHECKS["manifest"]
    failed = 0
    for label, fn, name in checks:
        if not (a / name).exists() or not (b / name).exists():
            print(f"KO  {label}: file {name} mancante")
            failed += 1
            continue
        ko, info = fn(a, b, name)
        print(f"{'OK' if not ko else 'KO'}  {label}" + (f"  ({'; '.join(info[:3])})" if info else ""))
        for line in ko[:10]:
            print(f"      {line}")
        if len(ko) > 10:
            print(f"      … altre {len(ko) - 10} differenze")
        failed += bool(ko)
    print("ESITO:", "OK" if not failed else f"KO ({failed} controlli)")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
