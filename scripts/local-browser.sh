#!/usr/bin/env bash
# Apre una finestra di Chrome che vede la COPIA LOCALE di geonode.dh.unica.it, senza toccare /etc/hosts.
# Solo questa istanza (profilo temporaneo e separato) risolve l'hostname su 127.0.0.1;
# il resto del sistema e il Chrome abituale continuano a vedere la produzione.
#
#   scripts/local-browser.sh [percorso]     es. scripts/local-browser.sh /geoserver/web/
set -euo pipefail

HOST=geonode.dh.unica.it
PROFILE="$(mktemp -d -t geonode-local-chrome.XXXXXX)"
trap 'rm -rf "$PROFILE"' EXIT

docker inspect -f '{{.State.Running}}' nginx4uni_cagliari 2>/dev/null | grep -q true \
  || { echo "KO: lo stack locale non è attivo (scripts/local.sh up)" >&2; exit 1; }

echo "Finestra COPIA LOCALE: $HOST -> 127.0.0.1 (profilo $PROFILE, eliminato alla chiusura)"
google-chrome \
  --user-data-dir="$PROFILE" \
  --host-resolver-rules="MAP $HOST 127.0.0.1, EXCLUDE localhost" \
  --no-first-run --no-default-browser-check \
  --disable-features=DnsOverHttps \
  "chrome://version" "https://$HOST${1:-/}" >/dev/null 2>&1
