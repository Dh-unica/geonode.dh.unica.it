#!/usr/bin/env bash
# Ripristina in locale un backup prodotto da scripts/backup-prod.sh (PIANO §5.3, §5.4).
# Lavora SOLO sul Docker locale e si rifiuta di partire se esistono già volumi uni_cagliari-*.
#
#   scripts/restore-local.sh <cartella-backup>
#
# - statics: volume overlay (lowerdir = <backup>/statics in sola lettura, scritture in <backup>/../local-overlay)
# - gsdatadir, nginxcerts, nginxconfd: volumi riempiti dai tar PRIMA di qualsiasi container
#   (un volume vuoto verrebbe popolato da Docker con il contenuto dell'immagine)
# - DB: avvia solo "db", ricrea geonode e geonode_data dai dump (pg_restore -C)
set -euo pipefail

BK="$(realpath "${1:?cartella backup}")"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
P=uni_cagliari
OVL="$(dirname "$BK")/local-overlay"
log() { printf '[%s] %s\n' "$(date +%T)" "$*" >&2; }
die() { log "KO: $*"; exit 1; }

[[ "$(docker context show)" == default ]] || die "il contesto Docker non è quello locale"
docker volume ls -q | grep -q "^${P}-" && die "esistono già volumi ${P}-*: rimuoverli a mano solo se sono la copia locale"

log "verifica sha256 dei file di backup"
(cd "$BK" && cat ./*.sha256 | sha256sum -c --quiet) || die "checksum non corrispondenti"

log "caricamento immagini"
for f in geonode-image-4.4.1.tar.gz other-images.tar.gz; do docker load -q < "$BK/$f"; done
[[ "$(docker image inspect -f '{{.Id}}' ${P}/geonode:4.4.1)" == sha256:de3ab4bb718e* ]] || die "ID immagine geonode diverso da de3ab4bb718e"
docker tag ${P}/geonode:4.4.1 ${P}/geonode:rollback-4.4.1

log "volumi"
mkdir -p "$OVL/upper" "$OVL/work"
docker volume create -d local -o type=overlay -o device=overlay \
  -o "o=lowerdir=$BK/statics,upperdir=$OVL/upper,workdir=$OVL/work" "${P}-statics" >/dev/null
fill() { # volume, tar
  docker volume create "${P}-$1" >/dev/null
  docker run --rm -i --network none -v "${P}-$1:/v" alpine tar -C /v --numeric-owner -xpf - < "$BK/$2"
}
fill gsdatadir gsdatadir.tar
fill nginxcerts nginxcerts.tar
fill nginxconfd nginxconfd.tar
for v in dbdata dbbackups backup-restore data tmp rabbitmq; do docker volume create "${P}-$v" >/dev/null; done

log "database"
"$ROOT/scripts/local.sh" up db
for _ in $(seq 60); do docker exec db4$P pg_isready -U postgres -q && break; sleep 2; done
sleep 5  # lasciare finire gli script di init dell'immagine postgis
psql_() { docker exec -i db4$P psql -U postgres -v ON_ERROR_STOP=1 -q "$@"; }
# ruoli: CREATE ROLE fallisce per quelli già creati dall'init, gli ALTER ROLE successivi allineano password e attributi
docker exec -i db4$P psql -U postgres -q < "$BK/globals.sql" 2>&1 | grep -v 'already exists' || true
for d in geonode geonode_data; do
  psql_ -c "DROP DATABASE IF EXISTS $d"   # database locale appena inizializzato e vuoto
  docker exec -i db4$P pg_restore -U postgres -C -d postgres --exit-on-error < "$BK/$d.dump"
done
log "restore completato: confrontare l'inventario locale con quello di prod"
