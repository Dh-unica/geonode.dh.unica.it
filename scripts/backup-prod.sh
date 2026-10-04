#!/usr/bin/env bash
# Backup della produzione GeoNode verso il locale, in streaming via SSH. Sulla produzione non scrive nulla
# (salvo un file temporaneo con gli sha256 in /tmp), i volumi sono montati :ro.
#
#   scripts/backup-prod.sh <cartella-destinazione> [elementi...]
#   elementi: globals db gsdatadir nginx statics image images   (default: tutti tranne images)
#
# Ogni elemento produce <nome> + <nome>.sha256 (calcolato su prod alla sorgente) e viene verificato in locale.
# Gli statics (senza static/, rigenerabile) vengono estratti in <dest>/statics/ con proprietari e permessi
# originali tramite un container locale; la verifica avviene sul manifest (scripts/inventory.sh).
set -euo pipefail

DEST="${1:?cartella di destinazione}"; shift
ITEMS=("${@:-globals db gsdatadir nginx statics image}")
read -r -a ITEMS <<< "${ITEMS[*]}"

HOST="${HOST:-dhlake@90.147.144.173}"
P="${P:-uni_cagliari}"
IMG="${IMG:-${P}/geonode:4.4.1}"
SSH=(ssh -o BatchMode=yes -o IdentitiesOnly=yes -i "$HOME/.ssh/id_rsa" -o ServerAliveInterval=30 "$HOST")

mkdir -p "$DEST"
log() { printf '[%s] %s\n' "$(date +%T)" "$*" >&2; }

# Esegue "cmd" su prod, scrive lo stream in $DEST/$name e confronta lo sha256 calcolato su prod con quello locale.
pull() {
  local name="$1" cmd="$2" remote_sum
  log "inizio $name"
  local t0=$SECONDS
  "${SSH[@]}" "set -o pipefail; $cmd | tee >(sha256sum | cut -d' ' -f1 > /tmp/.bk_$name.sha256)" > "$DEST/$name"
  sleep 1
  remote_sum="$("${SSH[@]}" "cat /tmp/.bk_$name.sha256 && rm -f /tmp/.bk_$name.sha256")"
  local local_sum; local_sum="$(sha256sum "$DEST/$name" | cut -d' ' -f1)"
  echo "$remote_sum  $name" > "$DEST/$name.sha256"
  if [[ "$remote_sum" != "$local_sum" ]]; then
    log "KO $name: sha256 prod=$remote_sum locale=$local_sum"; return 1
  fi
  log "OK $name ($(du -h "$DEST/$name" | cut -f1), $((SECONDS - t0)) s, sha256 identico)"
}

ro_tar() { # volume, opzioni tar extra
  echo "docker run --rm --network none -v ${P}-$1:/v:ro --entrypoint tar $IMG -C /v --numeric-owner -cf - $2 ."
}

for item in "${ITEMS[@]}"; do
  case "$item" in
    globals)   pull globals.sql "docker exec db4${P} pg_dumpall -U postgres --globals-only" ;;
    db)        pull geonode.dump "docker exec db4${P} pg_dump -U postgres -Fc geonode"
               pull geonode_data.dump "docker exec db4${P} pg_dump -U postgres -Fc geonode_data" ;;
    gsdatadir) pull gsdatadir.tar "$(ro_tar gsdatadir '--exclude=./gwc --exclude=./logs --exclude=./temp --exclude=./tmp')" ;;
    nginx)     pull nginxcerts.tar "$(ro_tar nginxcerts '')"
               pull nginxconfd.tar "$(ro_tar nginxconfd '')" ;;
    image)     "${SSH[@]}" "docker tag $IMG ${P}/geonode:rollback-4.4.1"
               pull geonode-image-4.4.1.tar.gz "docker save $IMG | gzip -1" ;;
    images)    pull other-images.tar.gz "docker save ${P}/geoserver:2.24.4-v1 ${P}/geoserver_data:2.24.4-v1 \
                 ${P}/postgis:15.3-latest ${P}/nginx:1.25.3-latest ${P}/letsencrypt:2.6.0-latest \
                 rabbitmq:3-alpine memcached:alpine | gzip -1" ;;
    statics)
      log "inizio statics (stream estratto in $DEST/statics)"
      t0=$SECONDS
      mkdir -p "$DEST/statics"
      "${SSH[@]}" "$(ro_tar statics '--exclude=./static')" \
        | docker run -i --rm --network none -v "$(realpath "$DEST/statics"):/out" --entrypoint tar alpine \
            -C /out --numeric-owner -xpf -
      log "fine statics ($((SECONDS - t0)) s): verificare con il manifest" ;;
    *) log "elemento sconosciuto: $item"; exit 2 ;;
  esac
done
log "backup completato in $DEST"
