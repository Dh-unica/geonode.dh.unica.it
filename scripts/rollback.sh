#!/usr/bin/env bash
# Rollback 4.4.5 -> 4.4.1 (PIANO §5.6). Gira sull'host Docker; nessuna cancellazione: i DB attuali vengono
# RINOMINATI in <db>_failed_445_<timestamp> e ripristinati dai dump; il .env viene copiato prima di modificarlo.
#
#   locale: CONFIRM=si COMPOSE="scripts/local.sh" ENV_FILE=app/.env.local DUMPS=backups/2026-10-04/hot \
#             bash scripts/rollback.sh
#   prod:   ssh dhlake@90.147.144.173 'cd /opt/projects/geonode441/uni-cagliari-geonode && CONFIRM=si \
#             COMPOSE=docker-compose ENV_FILE=.env DUMPS=/opt/projects/geonode441/backup/<data> bash -s' \
#             < scripts/rollback.sh
#
# DUMPS deve contenere geonode.dump e geonode_data.dump (backup a freddo) con i rispettivi .sha256.
set -euo pipefail

: "${COMPOSE:?comando compose}" "${ENV_FILE:?file .env}" "${DUMPS:?cartella dei dump}"
[[ "${CONFIRM:-}" == "si" ]] || { echo "Impostare CONFIRM=si per eseguire il rollback" >&2; exit 2; }
P=uni_cagliari
TS="$(date +%Y%m%d_%H%M%S)"
DB="db4${P}"
log() { printf '[%s] %s\n' "$(date +%T)" "$*" >&2; }
psql_() { docker exec -i "$DB" psql -U postgres -v ON_ERROR_STOP=1 -Atq "$@"; }
T0=$SECONDS

log "verifica dei dump"
(cd "$DUMPS" && sha256sum -c --quiet geonode.dump.sha256 geonode_data.dump.sha256)
docker image inspect "${P}/geonode:4.4.1" >/dev/null || { log "immagine 4.4.1 assente: docker load dal file salvato"; exit 1; }

log "stop di nginx, django, celery e geoserver (db resta attivo)"
$COMPOSE stop geonode celery django geoserver

for d in geonode geonode_data; do
  log "$d -> ${d}_failed_445_${TS} e restore dal dump"
  psql_ -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$d' AND pid <> pg_backend_pid()" >/dev/null
  psql_ -c "ALTER DATABASE $d RENAME TO ${d}_failed_445_${TS}"
  docker exec -i "$DB" pg_restore -U postgres -C -d postgres --exit-on-error < "$DUMPS/$d.dump"
done

log "immagine GeoNode -> 4.4.1 in $ENV_FILE (copia in $ENV_FILE.prima-del-rollback-$TS)"
cp -p "$ENV_FILE" "$ENV_FILE.prima-del-rollback-$TS"
sed -i 's/^GEONODE_BASE_IMAGE_VERSION=.*/GEONODE_BASE_IMAGE_VERSION=4.4.1/' "$ENV_FILE"
grep -q '^GEONODE_BASE_IMAGE_VERSION=4.4.1$' "$ENV_FILE"

log "riavvio completo e ordinato dello stack"
$COMPOSE stop
$COMPOSE up -d
log "rollback eseguito in $((SECONDS - T0)) s: ora inventario (scripts/compare-inventory.py) e smoke test"
log "DB precedenti conservati: geonode_failed_445_${TS}, geonode_data_failed_445_${TS}"
