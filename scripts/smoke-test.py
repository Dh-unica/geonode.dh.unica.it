#!/usr/bin/env python3
"""Test di accettazione automatici (PIANO §7) su copia locale o produzione.

    scripts/smoke-test.py local|prod [--inventory <cartella-inventario>] [--skip-css-put]

- local: le richieste vanno a 127.0.0.1 con l'hostname di produzione (curl --resolve): nessun traffico verso prod.
- prod:  le richieste vanno al server vero. Il login di prova crea una sessione e un token OAuth per il superuser
         (stesso effetto di un login dal browser). Il PUT dello stile riscrive lo STESSO contenuto (nessuna modifica).
Esce con 0 se tutti i controlli sono OK.
"""
import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

HOST = "geonode.dh.unica.it"
BASE = f"https://{HOST}"
PROD_SSH = ["ssh", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-i", str(Path.home() / ".ssh/id_rsa"),
            "dhlake@90.147.144.173"]

LOGIN_SNIPPET = """
from django.test import Client
from django.contrib.auth import get_user_model
from oauth2_provider.models import AccessToken
u = get_user_model().objects.filter(is_superuser=True, is_active=True).order_by('id').first()
c = Client(HTTP_HOST='geonode.dh.unica.it')
c.force_login(u, backend='django.contrib.auth.backends.ModelBackend')
assert AccessToken.objects.filter(user=u).exists()
print('SID=' + c.cookies['sessionid'].value)
"""


class Target:
    def __init__(self, name):
        self.name = name
        self.resolve = ["--resolve", f"{HOST}:443:127.0.0.1"] if name == "local" else []
        self.sid = None

    def host_cmd(self, cmd, stdin=None):
        full = cmd if self.name == "local" else PROD_SSH + [" ".join(cmd)]
        return subprocess.run(full, input=stdin, capture_output=True, text=True, timeout=300)

    def sql(self, query):
        r = self.host_cmd(["docker", "exec", "-i", "db4uni_cagliari", "psql", "-U", "postgres", "-d", "geonode",
                           "-AtF", "'\t'" if self.name == "prod" else "\t"], stdin=query)
        return [line.split("\t") for line in r.stdout.splitlines() if line]

    def login(self):
        r = self.host_cmd(["docker", "exec", "-i", "django4uni_cagliari", "python", "manage.py", "shell"],
                          stdin=LOGIN_SNIPPET)
        sids = [line[4:] for line in r.stdout.splitlines() if line.startswith("SID=")]
        self.sid = sids[-1] if sids else None
        return self.sid

    def curl(self, path, *extra, out=None, auth=False, timeout=120):
        url = path if path.startswith("http") else BASE + path
        cmd = ["curl", "-s", "-g", "--max-time", str(timeout), *self.resolve, "-o", out or "/dev/null",
               "-w", "%{http_code}\t%{content_type}\t%{size_download}", *extra]
        if auth and self.sid:
            cmd += ["-b", f"sessionid={self.sid}"]
        r = subprocess.run(cmd + [url], capture_output=True, text=True)
        code, ctype, size = (r.stdout.split("\t") + ["", "", "0"])[:3]
        return int(code or 0), ctype, int(float(size or 0))

    def get_json(self, path, auth=True):
        with tempfile.NamedTemporaryFile(suffix=".json") as f:
            code, _, _ = self.curl(path, out=f.name, auth=auth)
            return code, (json.loads(Path(f.name).read_text() or "null") if code == 200 else None)


results = []


def check(label, ok, detail=""):
    results.append(ok)
    print(f"{'OK' if ok else 'KO'}  {label}" + (f"  ({detail})" if detail else ""))


def png_not_blank(path):
    try:
        from PIL import Image
        img = Image.open(path).convert("RGBA")
        extrema = img.getextrema()
        return any(lo != hi for lo, hi in extrema)
    except Exception:
        return Path(path).stat().st_size > 1000


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("target", choices=["local", "prod"])
    ap.add_argument("--inventory", help="cartella inventario per confrontare i conteggi per tipo")
    ap.add_argument("--skip-css-put", action="store_true")
    ap.add_argument("--thumbs-out", help="file dove scrivere l'elenco delle thumbnail non raggiungibili")
    ap.add_argument("--thumbs-baseline", help="elenco di riferimento: OK se non ne mancano di nuove")
    args = ap.parse_args()
    t = Target(args.target)

    # 1. pagine principali
    for path in ("/", "/catalogue/", "/api/v2/resources?page_size=1"):
        code, _, _ = t.curl(path)
        check(f"GET {path}", code == 200, str(code))

    # 2. login amministratore (sessione + token OAuth2)
    check("login superuser con token OAuth2", bool(t.login()))
    code, _, _ = t.curl("/account/password/change/", auth=True)
    check("pagina riservata con la sessione", code == 200, str(code))

    # 3. conteggi per tipo dall'API (come superuser) contro il DB / inventario
    db_counts = {r[0]: int(r[1]) for r in t.sql("SELECT resource_type, count(*) FROM base_resourcebase "
                                                  "WHERE resource_type <> '' GROUP BY 1")}
    if args.inventory:
        inv = dict(l.split("\t") for l in (Path(args.inventory) / "13-resources-by-type.tsv").read_text().splitlines() if l)
        check("conteggi per tipo nel DB = inventario",
              all(int(inv.get(k, 0)) == v for k, v in db_counts.items()), json.dumps(db_counts))
    for rtype in ("dataset", "map", "document", "geostory"):
        code, data = t.get_json(f"/api/v2/resources?page_size=1&filter{{resource_type}}={rtype}")
        total = (data or {}).get("total")
        check(f"API {rtype}: totale", code == 200 and total == db_counts.get(rtype), f"API={total} DB={db_counts.get(rtype)}")

    # 4. GeoServer tramite GeoNode (autenticazione OAuth2 tra i due)
    code, data = t.get_json("/gs/rest/layers.json")
    check("REST GeoServer via /gs/ con sessione", code == 200 and data is not None, str(code))
    for svc, ver in (("WMS", "1.3.0"), ("WFS", "2.0.0"), ("WCS", "2.0.1")):
        with tempfile.NamedTemporaryFile() as f:
            code, _, size = t.curl(f"/geoserver/ows?service={svc}&version={ver}&request=GetCapabilities", out=f.name)
            ok = code == 200 and b"Capabilities" in Path(f.name).read_bytes()[:3000]
        check(f"{svc} GetCapabilities", ok, f"{code}, {size} byte")

    # 5. GetMap e GetLegendGraphic su 10 layer campione (7 vettoriali + 3 raster, scelti in modo deterministico)
    sample = t.sql("""
        (SELECT alternate, ST_XMin(ll_bbox_polygon), ST_YMin(ll_bbox_polygon), ST_XMax(ll_bbox_polygon), ST_YMax(ll_bbox_polygon)
           FROM base_resourcebase WHERE subtype='vector' AND ll_bbox_polygon IS NOT NULL ORDER BY id LIMIT 7)
        UNION ALL
        (SELECT alternate, ST_XMin(ll_bbox_polygon), ST_YMin(ll_bbox_polygon), ST_XMax(ll_bbox_polygon), ST_YMax(ll_bbox_polygon)
           FROM base_resourcebase WHERE subtype='raster' AND ll_bbox_polygon IS NOT NULL ORDER BY id LIMIT 3)""")
    for alt, x0, y0, x1, y1 in sample:
        bbox = f"{x0},{y0},{x1},{y1}"
        with tempfile.NamedTemporaryFile(suffix=".png") as f:
            code, ctype, size = t.curl(f"/geoserver/ows?service=WMS&version=1.1.1&request=GetMap&layers={alt}"
                                       f"&styles=&srs=EPSG:4326&bbox={bbox}&width=256&height=256&format=image/png"
                                       "&transparent=true", out=f.name, auth=True)
            ok = code == 200 and ctype.startswith("image/png") and png_not_blank(f.name)
        lcode, lctype, _ = t.curl(f"/geoserver/ows?service=WMS&version=1.1.1&request=GetLegendGraphic"
                                  f"&layer={alt}&format=image/png", auth=True)
        check(f"GetMap + legenda {alt}", ok and lcode == 200 and lctype.startswith("image/png"),
              f"map {code} {ctype} {size} byte, legend {lcode}")

    # 6. il bug di partenza: PUT di uno stile CSS attraverso GeoNode (/gs/ -> geoserver-restconfig).
    #    Si usa uno stile CSS NON collegato a nessun dataset: con dataset collegati GeoNode esegue set_styles,
    #    che per un difetto upstream (and invece di or sul workspace) toglie gli stili alternativi dello stesso
    #    workspace (verificato in locale sul dataset 570 il 2026-10-04). Si riscrive lo stesso contenuto.
    orphans = [r[0] for r in t.sql(
        "SELECT s.name FROM layers_style s WHERE NOT EXISTS (SELECT 1 FROM layers_dataset_styles x WHERE x.style_id=s.id) "
        "AND NOT EXISTS (SELECT 1 FROM layers_dataset d WHERE d.default_style_id=s.id) ORDER BY s.name")]
    style = None
    for name in orphans:
        code, data = t.get_json(f"/gs/rest/workspaces/geonode/styles/{name}.json")
        if code == 200 and ((data or {}).get("style") or {}).get("format") == "css":
            style = name
            break
    check("stile CSS non collegato a dataset disponibile per il test", style is not None, style or "")
    links_before = t.sql("SELECT count(*) FROM layers_dataset_styles")
    with tempfile.NamedTemporaryFile(suffix=".css") as f:
        code, _, size = t.curl(f"/gs/rest/workspaces/geonode/styles/{style}.css", out=f.name, auth=True)
        check(f"lettura stile CSS {style}", code == 200 and size > 0, f"{code}, {size} byte")
        if style and not args.skip_css_put and code == 200:
            pcode, _, _ = t.curl(f"/gs/rest/workspaces/geonode/styles/{style}?raw=true", "-X", "PUT",
                                 "-H", "Content-Type: application/vnd.geoserver.geocss+css",
                                 "--data-binary", f"@{f.name}", auth=True)
            check("PUT stile CSS ?raw=true via GeoNode (bug 502)", pcode == 200, str(pcode))
            with tempfile.NamedTemporaryFile(suffix=".css") as g:
                t.curl(f"/gs/rest/workspaces/geonode/styles/{style}.css", out=g.name, auth=True)
                check("contenuto dello stile invariato dopo il PUT",
                      Path(f.name).read_bytes() == Path(g.name).read_bytes())
            links_after = t.sql("SELECT count(*) FROM layers_dataset_styles")
            check("associazioni stile-dataset invariate", links_before == links_after,
                  f"{links_before[0][0]} -> {links_after[0][0]}")

    # 7. download di un dataset vettoriale e di un documento
    rows = t.sql("SELECT id FROM base_resourcebase WHERE subtype='vector' ORDER BY id LIMIT 1")
    code, data = t.get_json(f"/api/v2/resources/{rows[0][0]}")
    url = ((data or {}).get("resource") or {}).get("download_url")
    dcode, dctype, dsize = t.curl(url, auth=True, timeout=300) if url else (0, "", 0)
    note = ""
    if dcode != 200 and url:
        # errore transitorio osservato 2 volte il 2026-10-04 (GeoServer "DataSource not available after calling
        # dispose()" subito dopo un salvataggio di stile): si riprova una volta e lo si riporta
        import time
        time.sleep(5)
        first = dcode
        dcode, dctype, dsize = t.curl(url, auth=True, timeout=300)
        note = f", PRIMO TENTATIVO {first}, riuscito al secondo" if dcode == 200 else f", primo tentativo {first}"
    check("download dataset vettoriale", dcode == 200 and dsize > 0, f"{dcode} {dctype} {dsize} byte{note}")
    rows = t.sql("SELECT id FROM base_resourcebase WHERE resource_type='document' ORDER BY id LIMIT 1")
    dcode, dctype, dsize = t.curl(f"/documents/{rows[0][0]}/download", "-L", auth=True, timeout=300)
    check("download documento", dcode == 200 and dsize > 0, f"{dcode} {dctype} {dsize} byte")

    # 8. thumbnail di tutte le risorse
    thumbs, page = [], 1
    while True:
        code, data = t.get_json(f"/api/v2/resources?page_size=100&page={page}")
        if code != 200 or not data:
            break
        thumbs += [r.get("thumbnail_url") for r in data["resources"] if r.get("thumbnail_url")]
        if not data["links"].get("next"):
            break
        page += 1
    bad = []
    for url in thumbs:
        code, _, _ = t.curl(url, "-I", timeout=30)
        if code != 200:
            bad.append(url)
    if args.thumbs_out:
        Path(args.thumbs_out).write_text("\n".join(sorted(bad)) + "\n")
    known = set(Path(args.thumbs_baseline).read_text().split()) if args.thumbs_baseline else set()
    new = sorted(set(bad) - known)
    check(f"thumbnail ({len(thumbs)} risorse)", not new,
          f"{len(bad)} non raggiungibili, {len(bad) - len(new)} già note, nuove: {new[:3]}")

    print("ESITO:", "OK" if all(results) else f"KO ({results.count(False)} controlli)")
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
