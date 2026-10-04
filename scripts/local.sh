#!/usr/bin/env bash
# Wrapper per lo stack locale: impone override, .env.local e i controlli di sicurezza (PIANO §5.2, §5.4).
#
#   scripts/local.sh check            verifica lock di init e isolamento dei container attivi
#   scripts/local.sh up [servizi]     controlla il lock, avvia, verifica l'isolamento (se KO ferma tutto)
#   scripts/local.sh <comando compose> qualunque altro comando docker compose (es. ps, logs -f django, stop)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
P=uni_cagliari
PROD_IP=90.147.144.173
COMPOSE=(docker compose --project-directory "$ROOT/app" --env-file "$ROOT/app/.env.local"
         -f "$ROOT/app/docker-compose.yml" -f "$ROOT/overrides/docker-compose.local.yml")

die() { echo "KO: $*" >&2; exit 1; }

check_lock() {
  docker run --rm --network none -v "${P}-statics:/v:ro" alpine test -f /v/geonode_init.lock \
    || die "geonode_init.lock assente nel volume statics: django ricaricherebbe i fixture (reset admin/OAuth)"
  grep -qiE '^FORCE_REINIT=(false|)$' "$ROOT/app/.env.local" || die "FORCE_REINIT non è false in .env.local"
  echo "OK lock di init presente, FORCE_REINIT=false"
}

check_config() { # prima dell'avvio: extra_hosts sui servizi giusti, porte solo su 127.0.0.1, letsencrypt spento
  "${COMPOSE[@]}" config --format json | python3 -c '
import json, re, sys
cfg = json.load(sys.stdin)["services"]
ko = []
for s in ("django", "celery", "geoserver"):
    eh = cfg[s].get("extra_hosts") or {}
    eh = eh if isinstance(eh, dict) else dict(re.split("[=:]", x, maxsplit=1) for x in eh)
    if eh.get("geonode.dh.unica.it") not in ("host-gateway", ["host-gateway"]):
        ko.append(f"{s}: extra_hosts mancante")
for s, c in cfg.items():
    for p in c.get("ports") or []:
        if p.get("host_ip") != "127.0.0.1":
            ko.append("%s: porta %s esposta su %s" % (s, p.get("published"), p.get("host_ip") or "0.0.0.0"))
if "letsencrypt" in cfg:
    ko.append("letsencrypt attivo")
print("\n".join("KO " + k for k in ko) or "OK config locale: extra_hosts, porte su 127.0.0.1, letsencrypt spento")
sys.exit(1 if ko else 0)' || die "configurazione locale non isolata"
}

check_isolation() {
  local c ip ok=1
  for c in django4$P celery4$P geoserver4$P; do
    docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null | grep -q true || continue
    ip="$(docker exec "$c" getent hosts geonode.dh.unica.it | awk '{print $1}')"
    if [[ "$ip" == "$PROD_IP" || ! "$ip" =~ ^(127\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]]; then
      echo "KO $c: geonode.dh.unica.it -> '$ip' (non locale)"; ok=0
    else
      echo "OK $c: geonode.dh.unica.it -> $ip"
    fi
  done
  [[ $ok == 1 ]]
}

case "${1:-}" in
  check) check_config; check_lock; check_isolation ;;
  up)
    shift
    check_config; check_lock
    "${COMPOSE[@]}" up -d "$@"
    if ! check_isolation; then
      "${COMPOSE[@]}" stop
      die "isolamento non garantito: stack fermato"
    fi ;;
  "") die "uso: $0 check|up|<comando compose>" ;;
  *) "${COMPOSE[@]}" "$@" ;;
esac
