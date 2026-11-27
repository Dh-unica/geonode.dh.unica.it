# Incidente: GeoServer spento dal 2026-11-20 al 2026-11-27

## Sintomo

Le mappe di GeoNode incorporate nei siti (per esempio i portolani della monarchia ispanica su storia.dh.unica.it/asmsa) mostravano l'elenco dei layer con il bordo rosso e il punto esclamativo, ma nessun layer sulla mappa. GeoNode (Django) e le API v2 funzionavano: mappa 393 e dataset erano tutti registrati. Era fermo solo GeoServer: `/geoserver/ows` rispondeva 502 attraverso nginx e la porta 8080 rifiutava la connessione.

## Sequenza (ore UTC, ricostruita il 2026-11-27)

| Ora (2026-11-20) | Evento | Fonte |
|---|---|---|
| 06:48–06:53 | Memoria esaurita: il kernel uccide 7 processi uwsgi di GeoNode e `cbagentd`, l'agente di sicurezza dell'ateneo | `dmesg -T` |
| 07:32:34 | GeoServer riparte | `docker inspect` (`StartedAt`) |
| 07:32:56 | GeoServer viene ucciso con SIGKILL (exit 137, `OOMKilled=false`) a metà avvio, 22 s dopo la partenza | `docker inspect` (`FinishedAt`) |
| 07:42:46 | Celery riparte. Django e db non vengono toccati | `docker inspect` |

Tra le 06:00 e le 07:00 nginx ha ricevuto 105 richieste: l'esaurimento di memoria non viene da un picco di traffico, ma dalla configurazione (GeoServer con 4 GB fissi di heap, uWSGI fino a 128 processi, swap già in uso).

Chi ha fermato GeoServer alle 07:32 non è ricostruibile da `dhlake`: `auth.log` è leggibile solo dal gruppo `adm` e `wtmp` non registra gli accessi recenti. Lo stop di 22 s dopo l'avvio e la mancata ripartenza fanno pensare a un intervento manuale durante l'emergenza.

## Perché non è ripartito da solo

Il container ha `restart: unless-stopped`, ma `docker start` falliva con:

```
Error response from daemon: task 802abd6a… already exists: unknown
```

Lo shim di containerd del vecchio container (`containerd-shim-runc-v2 … -id 802abd6a…`, PID 3242131, root) era rimasto vivo senza processi figli. Finché esiste, Docker non può riavviare quel container. `dhlake` non ha sudo, quindi non può chiuderlo.

Il monitor esterno (Better Uptime) interroga solo la home di GeoNode, che ha continuato a rispondere 200: nessun avviso per 7 giorni.

## Ripristino (2026-11-27, 14:09 UTC)

Verifiche prima della ricreazione:

- il container monta solo volumi con nome (`uni_cagliari-gsdatadir`, `-statics`, `-data`, `-tmp`, `-backup-restore`);
- l'hash di configurazione del container coincide con `docker-compose config --hash=geoserver` (`c01cdcfe27e4561c`), quindi il nuovo container è identico al vecchio.

Comando, da `/opt/projects/geonode441/uni-cagliari-geonode`:

```bash
docker-compose up -d --no-deps --force-recreate geoserver
```

Nuovo container `8e4403d2c5a5`, *healthy* dopo circa 60 s. Django, db, nginx e celery non sono stati toccati.

Verifiche dopo:

- GetMap WMS 200 (PNG) su tutti i 10 layer della mappa 393 e GetCapabilities 200;
- screenshot della mappa incorporata (`/maps/393/embed`) con i quattro portolani, i punti dei derroteros, la costa e i paesi.

Memoria subito dopo: 5,5 GB usati e circa 2 GB disponibili, contro i 4,4 GB disponibili senza GeoServer. Il margine è basso: vedi [PROSSIMI-PASSI.md](../PROSSIMI-PASSI.md), priorità alta.

## Da fare

- Rivedere heap di GeoServer e processi uWSGI (provando prima in locale).
- Aggiungere un controllo esterno su `/geoserver/ows?service=WMS&request=GetCapabilities`.
- Far chiudere al sistemista lo shim orfano: `sudo kill 3242131`.
