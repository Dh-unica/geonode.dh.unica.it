# Stato e prossimi passi

Questo è il documento di riferimento per sapere **cosa è stato fatto e cosa manca** su geonode.dh.unica.it. Va aggiornato a ogni intervento: si spunta ciò che è chiuso e si aggiungono le novità, con data.

Ultimo aggiornamento: **2026-10-04**

## Dove siamo

| | |
|---|---|
| Versione in produzione | GeoNode **4.4.5** (dal 2026-10-04, tag `prod-4.4.5`), GeoServer 2.24.4-v1, PostGIS 15.3 |
| Immagine GeoNode | `uni_cagliari/geonode:4.4.5`, ID `7edb1d4fbf73`, costruita da [`app/Dockerfile.4.4.5`](app/Dockerfile.4.4.5) con le [patch locali](app/patches/README.md) |
| Ultimo intervento | Fase A del [piano](PIANO-AGGIORNAMENTO.md): procedura ed esito nel [runbook](RUNBOOK-PRODUZIONE.md) |
| Backup | Backup a freddo del 2026-10-04 su prod (`/opt/projects/geonode441/backup/2026-10-04`) e in locale (`backups/2026-10-04/cold`, non versionato). **Nessun backup periodico** |

## Fatto

- [x] Repository privato con la copia esatta della produzione (tag `prod-4.4.1`) — 2026-10-04
- [x] README del progetto — 2026-10-04
- [x] Strumenti: inventario, backup a caldo e a freddo, copia locale isolata, confronto, smoke test, rollback — 2026-10-04
- [x] Copia locale fedele alla produzione, upgrade e rollback provati — 2026-10-04
- [x] **Fase A: aggiornamento a 4.4.5**, risolto il 502 sugli stili CSS — 2026-10-04
- [x] Correzione di `set_styles` (stili alternativi persi al salvataggio), che la build controlla — 2026-10-04
- [x] Pulizia del DB (da 3,7 GB a 75 MB) e cron giornaliero `clearsessions` alle 03:30 — 2026-10-04

## Da fare

### Priorità alta

- [ ] **Backup periodico fuori dal server.** Dump giornaliero di `geonode` e `geonode_data` più copia settimanale di statics e data dir di GeoServer, su una macchina diversa. Prima va scelta la destinazione. Gli script [`cold-backup-prod.sh`](scripts/cold-backup-prod.sh) e [`backup-prod.sh`](scripts/backup-prod.sh) sono una base. Lezione dall'incidente del 2026-10-04: mai stream da `docker run` senza `--log-driver none`.
- [ ] **Chiudere la porta 8080 di GeoServer**, oggi esposta su Internet (`ports: 8080:8080` nel `docker-compose.yml`). Il traffico passa già da nginx su `/geoserver/`. Va provato in locale prima.
- [ ] **Rigenerare i segreti predefiniti.** `SECRET_KEY` e il client OAuth2 GeoNode↔GeoServer (`OAUTH2_CLIENT_ID`/`SECRET`) sono i valori pubblici del template geonode-project. Il client va aggiornato sia in GeoNode sia nella configurazione OAuth di GeoServer. Valutare anche le password DB predefinite (`geonode`/`geonode_data`).
- [ ] **Cambiare le credenziali passate in chat**: admin GeoNode e password SSH di `dhlake`. Decidere anche se tenere la chiave SSH di Alessandro aggiunta il 2026-10-04 (`~/.ssh/authorized_keys` di `dhlake`).

### Priorità media

- [ ] **148 file mancanti** in `uploaded/layers/` (caricamenti del 2022) referenziati dagli asset ma assenti dal disco. Mancavano già prima del 2026-10-04. I layer funzionano perché i dati stanno in PostGIS: va capito se gli asset vanno corretti o rimossi.
- [ ] **5 thumbnail con URL malformati** (elenco in `backups/2026-10-04/thumbs-missing-4.4.1.txt`): rigenerarle.
- [ ] **Harvester `ide.cime.es`** configurato come GeoNode, ma non risponde in JSON: produce un errore nel log di Celery ogni 10 minuti (circa 1.200 al giorno). Correggere il tipo o disattivarlo.
- [ ] **Memoria del server** (7,8 GB): GeoServer ha `-Xms4G -Xmx4G` e uWSGI arriva fino a 128 processi. Rivedere i valori.
- [ ] **Log di uWSGI** (`/var/log/geonode.log` nel container django) non ruotato: impostare `log-maxsize` o una rotazione.
- [ ] **Celery beat**: verificare che il task `celery.backend_cleanup` giri. Nel DB l'ultima esecuzione registrata è del 2024-11-14.

### Pulizia (dopo il 2026-11-04)

- [ ] Cancellare i DB della prova di rollback in locale e i volumi della copia locale (`scripts/local.sh down`, poi rimozione volumi solo **dopo** aver verificato che sono quelli locali)
- [ ] Rimuovere backup a freddo e immagine `uni_cagliari/geonode:rollback-4.4.1` su prod, se la 4.4.5 è stabile
- [ ] Valutare la rimozione su prod del vecchio backup di nov 2024 (`backup/backup_restore/2024-11-25_165657.zip`, 14 GB), dei container `*4geonode` della 3.2 fermi da 22 mesi e dell'immagine `uni_cagliari/geonode:4.3.1`. Prima chiedere e verificare.

### Facoltativo

- [ ] Segnalare a GeoNode il difetto di `set_styles` (`and` invece di `or` sul workspace, presente anche nel `master`) con una issue o una PR.
- [ ] `pyopenssl 24.1.0` rimasto nell'immagine dichiara incompatibile `cryptography 45`. Funziona e nessun pacchetto lo usa: rimuoverlo alla prossima build.

### Fase B: 4.4.5 → 5.0.3 → 5.1.0

Da dettagliare nel [piano](PIANO-AGGIORNAMENTO.md#10-fase-b-successiva-da-pianificare-445--503--510) con la stessa disciplina della fase A: copia locale, inventario, smoke test, rollback provato.

- [ ] Rivedere le [patch locali](app/patches/README.md): la build fallirà apposta se non si applicano più
- [ ] Redis al posto di RabbitMQ, Ubuntu 24.04, Python 3.12, Django 5, importer nel core
- [ ] GeoServer 2.27/2.28: la data dir **non torna indietro**, quindi serve un backup completo
- [ ] PostGIS 3.5, `migrate_file_to_assets`, porting delle personalizzazioni (`_geonode_config.html`, `fixup_missing_maplayers`)
- [ ] Installare `docker compose` v2 sul server
