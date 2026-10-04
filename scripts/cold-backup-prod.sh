#!/usr/bin/env bash
# Backup "a freddo" durante il freeze (PIANO §5.3, passo A7). Va lanciato dal locale, DOPO aver fermato
# nginx, django e celery in produzione (db e geoserver restano attivi per i dump).
#
#   scripts/cold-backup-prod.sh <AAAA-MM-GG>
#
# Copia 1: su prod in /opt/projects/geonode441/backup/<data>/   Copia 2: in locale in backups/<data>/cold/
# Contenuto: globals, dump di geonode e geonode_data, data dir GeoServer (senza gwc/logs/temp/tmp), nginx,
# immagine 4.4.1 (rollback). Gli statics non si duplicano su prod (spazio): in locale si verifica il manifest.
# Nessuno stream passa da "docker run" senza --log-driver none (incidente 2026-10-04).
set -euo pipefail

DAY="${1:?data AAAA-MM-GG}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${HOST:-dhlake@90.147.144.173}"
P=uni_cagliari
REMOTE="/opt/projects/geonode441/backup/$DAY"
LOCAL="$ROOT/backups/$DAY/cold"
SSH=(ssh -o BatchMode=yes -o IdentitiesOnly=yes -i "$HOME/.ssh/id_rsa" -o ServerAliveInterval=30 "$HOST")
log() { printf '[%s] %s\n' "$(date +%T)" "$*" >&2; }
T0=$SECONDS

log "controlli preliminari su prod"
"${SSH[@]}" bash -s <<EOF
set -euo pipefail
for c in nginx4$P django4$P celery4$P; do
  [ "\$(docker inspect -f '{{.State.Running}}' \$c)" = false ] || { echo "KO \$c è ancora attivo: fermarlo prima del backup a freddo"; exit 1; }
done
q=\$(docker exec rabbitmq4$P rabbitmqctl -q list_queues messages | awk '{s+=\$1} END {print s+0}')
echo "messaggi in coda RabbitMQ: \$q"
free=\$(df -BG --output=avail /opt | tail -1 | tr -dc 0-9)
[ "\$free" -ge 20 ] || { echo "KO spazio libero \${free} GB < 20 GB"; exit 1; }
mkdir -p "$REMOTE"
EOF

log "dump e archivi su prod in $REMOTE"
"${SSH[@]}" bash -s <<EOF
set -euo pipefail
cd "$REMOTE"
docker exec db4$P pg_dumpall -U postgres --globals-only > globals.sql
docker exec db4$P pg_dump -U postgres -Fc geonode > geonode.dump
docker exec db4$P pg_dump -U postgres -Fc geonode_data > geonode_data.dump
for v in gsdatadir nginxcerts nginxconfd; do
  ex=""; [ \$v = gsdatadir ] && ex="--exclude=./gwc --exclude=./logs --exclude=./temp --exclude=./tmp"
  docker run --rm --log-driver none --network none -v ${P}-\$v:/v:ro --entrypoint tar ${P}/geonode:4.4.1 \
    -C /v --numeric-owner -cf - \$ex . > \$v.tar
done
docker tag ${P}/geonode:4.4.1 ${P}/geonode:rollback-4.4.1
[ -s geonode-image-4.4.1.tar.gz ] || docker save ${P}/geonode:4.4.1 | gzip -1 > geonode-image-4.4.1.tar.gz
for f in globals.sql geonode.dump geonode_data.dump gsdatadir.tar nginxcerts.tar nginxconfd.tar geonode-image-4.4.1.tar.gz; do
  sha256sum \$f > \$f.sha256
done
docker run --rm --log-driver none --network none -v "\$PWD":/b:ro ${P}/postgis:15.3-latest sh -c \
  'pg_restore -l /b/geonode.dump >/dev/null && pg_restore -l /b/geonode_data.dump >/dev/null' && echo "pg_restore --list: OK"
ls -la; df -h /opt | tail -1
EOF

log "copia 2 in locale ($LOCAL) e verifica sha256"
mkdir -p "$LOCAL"
scp -q -o BatchMode=yes -o IdentitiesOnly=yes -i "$HOME/.ssh/id_rsa" "$HOST:$REMOTE/*" "$LOCAL/"
(cd "$LOCAL" && sha256sum -c --quiet ./*.sha256) && log "OK sha256 identici su prod e in locale"
log "backup a freddo completato in $((SECONDS - T0)) s"
