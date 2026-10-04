#!/usr/bin/env bash
# Inventario ("fotografia") di un'installazione GeoNode uni_cagliari, in sola lettura.
# Gira sull'host Docker e scrive su stdout un tar.gz con un file per ogni controllo.
#
#   prod:   ssh dhlake@90.147.144.173 'bash -s' < scripts/inventory.sh > inv.tgz
#   locale: P=uni_cagliari_local bash scripts/inventory.sh > inv.tgz
#
# Variabili: P = prefisso volumi/compose (default uni_cagliari), S = suffisso container (default = P),
#            IMG = immagine con GNU find per i manifest (default: quella del container django).
set -euo pipefail

P="${P:-uni_cagliari}"
S="${S:-$P}"
DB="db4${S}"
DJANGO="django4${S}"
IMG="${IMG:-$(docker inspect -f '{{.Config.Image}}' "$DJANGO" 2>/dev/null || echo "${P}/geonode:4.4.1")}"

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

psql_q() { docker exec "$DB" psql -U postgres -d "$1" -AtF $'\t' -v ON_ERROR_STOP=1 -c "$2"; }

ROWCOUNT_SQL="
SELECT table_schema||'.'||table_name,
       (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', table_schema, table_name), false, true, '')))[1]::text
FROM information_schema.tables
WHERE table_type = 'BASE TABLE' AND table_schema NOT IN ('pg_catalog', 'information_schema')
ORDER BY 1;"

{
  echo "date=$(date -u +%FT%TZ)"
  echo "host=$(hostname)"
  echo "prefix=$P manifest_image=$IMG"
  docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | grep "4${S}" | sort
  for c in $(docker ps -a --format '{{.Names}}' | grep "4${S}" | sort); do
    printf '%s\t%s\n' "$c" "$(docker inspect -f '{{.Image}}' "$c")"
  done
} > "$OUT/00-meta.txt"

# --- Database ---------------------------------------------------------------
for d in geonode geonode_data; do
  psql_q "$d" "$ROWCOUNT_SQL" > "$OUT/10-rowcount-$d.tsv"
  psql_q "$d" "SELECT extname, extversion FROM pg_extension ORDER BY 1" > "$OUT/11-extensions-$d.tsv"
done
psql_q geonode "SELECT app, name FROM django_migrations ORDER BY app, name" > "$OUT/12-migrations-geonode.tsv"
psql_q geonode_data "SELECT app, name FROM django_migrations ORDER BY app, name" > "$OUT/12-migrations-geonode_data.tsv" 2>/dev/null || true
psql_q geonode "SELECT resource_type, count(*) FROM base_resourcebase GROUP BY 1 ORDER BY 1" > "$OUT/13-resources-by-type.tsv"
psql_q geonode "
SELECT 'users', count(*) FROM people_profile
UNION ALL SELECT 'superusers', count(*) FROM people_profile WHERE is_superuser
UNION ALL SELECT 'groups', count(*) FROM auth_group
UNION ALL SELECT 'groupprofiles', count(*) FROM groups_groupprofile
UNION ALL SELECT 'guardian_user', count(*) FROM guardian_userobjectpermission
UNION ALL SELECT 'guardian_group', count(*) FROM guardian_groupobjectpermission
UNION ALL SELECT 'oauth2_apps', count(*) FROM oauth2_provider_application" > "$OUT/14-people-perms.tsv"
psql_q geonode "SELECT max(last_login) FROM people_profile" > "$OUT/15-last-login.txt"
psql_q postgres "SELECT datname, pg_database_size(datname) FROM pg_database ORDER BY 1" > "$OUT/16-db-sizes.tsv"

# --- GeoServer REST (solo se GeoServer e django sono attivi) ----------------
if docker exec "$DJANGO" true 2>/dev/null; then
  docker exec -i "$DJANGO" python3 - > "$OUT/20-geoserver-rest.tsv" 2>&1 <<'PY' || echo "REST non disponibile" >> "$OUT/20-geoserver-rest.tsv"
import base64, json, os, urllib.request
base = os.environ["GEOSERVER_LOCATION"].rstrip("/") + "/rest/"
auth = base64.b64encode(f'{os.environ["GEOSERVER_ADMIN_USER"]}:{os.environ["GEOSERVER_ADMIN_PASSWORD"]}'.encode()).decode()
def get(path):
    req = urllib.request.Request(base + path, headers={"Authorization": "Basic " + auth, "Accept": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=60))
def names(obj, *keys):
    for k in keys:
        obj = (obj or {}).get(k) if isinstance(obj, dict) else None
    return sorted(x["name"] for x in (obj or []))
ws = names(get("workspaces.json"), "workspaces", "workspace")
for w in ws:
    print("workspace", w, sep="\t")
    for s in names(get(f"workspaces/{w}/styles.json"), "styles", "style"):
        print("style", f"{w}:{s}", sep="\t")
for s in names(get("styles.json"), "styles", "style"):
    print("style", s, sep="\t")
for l in names(get("layers.json"), "layers", "layer"):
    print("layer", l, sep="\t")
for g in names(get("layergroups.json"), "layerGroups", "layerGroup"):
    print("layergroup", g, sep="\t")
PY
else
  echo "django non attivo: REST saltato" > "$OUT/20-geoserver-rest.tsv"
fi

# --- Manifest dei file (container usa e getta, volumi in sola lettura, senza rete) ---
manifest() { # volume, sottocartelle escluse...
  local vol="$1"; shift
  local prune=()
  for x in "$@"; do prune+=(-path "/v/$x" -prune -o); done
  docker run --rm --network none --entrypoint find -v "${vol}:/v:ro" "$IMG" \
    /v "${prune[@]}" -printf '%y\t%s\t%T@\t%P\n' \
    | awk -F'\t' 'BEGIN{OFS="\t"} $4!="" {split($3,t,"."); print $1,$2,t[1],$4}' | LC_ALL=C sort -t $'\t' -k4
}
manifest "${P}-statics" static > "$OUT/30-manifest-statics.tsv"
manifest "${P}-gsdatadir" gwc logs temp tmp > "$OUT/31-manifest-gsdatadir.tsv"
for f in 30-manifest-statics 31-manifest-gsdatadir; do
  awk -F'\t' '$1=="f"{n++; b+=$2} END{printf "files=%d bytes=%d\n", n, b}' "$OUT/$f.tsv" > "$OUT/$f.summary"
done
docker run --rm --network none --entrypoint cat -v "${P}-statics:/v:ro" "$IMG" /v/geonode_init.lock > "$OUT/32-geonode_init.lock" 2>&1 || echo "MANCANTE" > "$OUT/32-geonode_init.lock"
docker run --rm --network none --entrypoint cat -v "${P}-gsdatadir:/v:ro" "$IMG" /v/geoserver_init.lock > "$OUT/33-geoserver_init.lock" 2>&1 || echo "MANCANTE" > "$OUT/33-geoserver_init.lock"

tar -C "$OUT" -czf - .
