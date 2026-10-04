# Runbook: aggiornamento GeoNode 4.4.1 → 4.4.5 in produzione

Questo runbook si applica alla fase A del [piano](PIANO-AGGIORNAMENTO.md). I comandi e i tempi vengono dalla prova sulla copia locale del 2026-10-04. Il percorso completo è stato provato in locale: upgrade, test, pulizia, rollback e nuovi test.

Convenzioni:

- `PROD` = `ssh -o IdentitiesOnly=yes -i ~/.ssh/id_rsa dhlake@90.147.144.173`
- `DIR` = `/opt/projects/geonode441/uni-cagliari-geonode`
- `DAY` = data della finestra (`AAAA-MM-GG`)
- In produzione si usa `docker-compose` v1 (1.27.3), sempre da dentro `DIR`.
- I comandi `scripts/…` si lanciano dalla radice del repo in locale.

> [!CAUTION]
> Restano validi tutti i divieti del §5.2 del piano: niente `down -v`, `volume rm/prune`, `system prune`, `docker-purge.sh`, `rmi uni_cagliari/*`, `FORCE_REINIT=True`, build su prod, `DROP DATABASE`.
> Durante la finestra lo stack locale deve essere **spento** (`scripts/local.sh stop`).

## Tempi misurati in locale

| Passo | Tempo |
|---|---|
| Stop dello stack | 12 s |
| Avvio dello stack fino a django e geoserver *healthy* | 60–75 s |
| Migrazioni 4.4.5 (3 migrazioni) | comprese nell'avvio |
| Smoke test completo | ~50 s |
| Pulizia DB: `TRUNCATE` + cancellazione sessioni scadute | 6 s |
| `VACUUM FULL` sulle tabelle pulite | 6 s (il DB passa da 3.657 MB a 60 MB) |
| Rollback completo (restore di entrambi i DB e riavvio) | 2 min 47 s |
| Backup a caldo prod→locale (dump, data dir, immagini) | ~5 min (statics: 17 min, già fatto) |

**Downtime stimato: 25–35 minuti** (freeze, backup a freddo, upgrade, verifiche, pulizia). Un eventuale rollback aggiunge circa 10 minuti, verifiche comprese.

## 0. Preparazione (giorno stesso, senza downtime)

1. Lo stack locale è spento: `scripts/local.sh stop`.
2. Spazio su prod ≥ 20 GB: `PROD 'df -h /'`.
3. **Pre-caricamento dell'immagine 4.4.5 testata**. L'operazione aggiunge un'immagine e non tocca i container attivi:

   ```bash
   docker save uni_cagliari/geonode:4.4.5 | gzip -1 | PROD 'gunzip | docker load'
   PROD "docker image inspect -f '{{.Id}}' uni_cagliari/geonode:4.4.5"   # deve iniziare con sha256:7edb1d4fbf73
   ```

4. Inventario di riferimento prima del freeze:

   ```bash
   mkdir -p backups/$DAY/inventory-pre && PROD 'bash -s' < scripts/inventory.sh | tar -xzf - -C backups/$DAY/inventory-pre
   ```

## A7. Freeze e backup a freddo (inizio del downtime)

1. Alessandro avvisa gli utenti.
2. Si fermano gli unici servizi che scrivono:

   ```bash
   PROD "cd $DIR && docker-compose stop geonode django celery"
   ```

3. Backup a freddo, con copia 1 su prod e copia 2 in locale verificata via sha256. Lo script controlla anche che i servizi siano fermi, le code RabbitMQ e lo spazio libero:

   ```bash
   scripts/cold-backup-prod.sh $DAY
   ```

4. Inventario al freeze e confronto con il backup degli statics già in locale. Se ci sono file nuovi, si scaricano prima di proseguire:

   ```bash
   mkdir -p backups/$DAY/inventory-freeze && PROD 'bash -s' < scripts/inventory.sh | tar -xzf - -C backups/$DAY/inventory-freeze
   scripts/compare-inventory.py backups/2026-10-04/inventory-local-backup backups/$DAY/inventory-freeze --only manifest
   ```

**Si va avanti solo se** il backup a freddo e il confronto degli statics danno OK.

## A8. Upgrade

```bash
PROD "cd $DIR && cp -p .env .env.prima-di-4.4.5-$DAY \
  && sed -i 's/^GEONODE_BASE_IMAGE_VERSION=4.4.1$/GEONODE_BASE_IMAGE_VERSION=4.4.5/' .env \
  && grep -n '^GEONODE_BASE_IMAGE_VERSION' .env \
  && docker-compose stop && docker-compose up -d"
```

- Si fanno **stop e avvio completi**: cambiando il `.env` cambia l'ambiente di tutti i servizi (anche `db` viene ricreato), quindi conviene un riavvio ordinato di tutto.
- `up -d` **non** ricostruisce l'immagine, perché `uni_cagliari/geonode:4.4.5` esiste già.

Si attende che django e geoserver siano *healthy* (circa 75 s), poi si controlla il log di django:

```bash
PROD 'docker logs django4uni_cagliari 2>&1 | grep -E "Applying|No migrations|Traceback" | head'
```

Attese esattamente 3 migrazioni su entrambi i DB: `base.0093_alter_thesaurus_slug`, `base.0094_fix_otherrestrictions_codetype`, `importer.0007_align_resourcehandler_with_asset`. L'ultima è solo una migrazione di dati, senza effetti su questa installazione: `importer_resourcehandlerinfo` resta a 263 righe.

## A9. Verifiche (decisione: riapertura o rollback)

```bash
mkdir -p backups/$DAY/inventory-445 && PROD 'bash -s' < scripts/inventory.sh | tar -xzf - -C backups/$DAY/inventory-445
scripts/compare-inventory.py backups/$DAY/inventory-freeze backups/$DAY/inventory-445
scripts/smoke-test.py prod --inventory backups/$DAY/inventory-freeze --thumbs-baseline backups/2026-10-04/thumbs-missing-4.4.1.txt
```

Esito atteso dal confronto, provato in locale:

- `django_migrations`: +3 righe in `geonode` e +3 in `geonode_data`, insieme ai KO "migrazioni" che ne derivano. Sono le uniche differenze ammesse.
- Tutto il resto OK.
- In `gsdatadir` possono comparire come "riscritti all'avvio" i file elencati in `compare-inventory.py`.

Esito atteso dallo smoke test: **tutto OK**, compreso `PUT stile CSS … (bug 502) (200)`.

- Il PUT viene fatto su uno stile CSS **non collegato a nessun dataset**, con lo stesso contenuto: non modifica nulla, salvo la data dei file di quello stile e l'anteprima della legenda.
- Il login di prova crea una sessione e un token OAuth per il superuser.

**Rollback** se un controllo dà KO e non si risolve entro 30 minuti dall'avvio della 4.4.5 (§5.6 del piano).

## A10. Pulizia del DB (a sito fermo)

```bash
PROD "cd $DIR && docker-compose stop geonode django celery"
PROD "docker exec db4uni_cagliari psql -U postgres -d geonode -v ON_ERROR_STOP=1 -c \"BEGIN;
  TRUNCATE monitoring_metricvalue, monitoring_requestevent_resources, monitoring_requestevent,
           monitoring_exceptionevent, monitoring_metriclabel, monitoring_metricnotificationcheck;
  DELETE FROM django_session WHERE expire_date < now(); COMMIT;\""
PROD "docker exec db4uni_cagliari psql -U postgres -d geonode -c 'VACUUM (FULL, ANALYZE) django_session,
  monitoring_metricvalue, monitoring_requestevent_resources, monitoring_requestevent,
  monitoring_exceptionevent, monitoring_metriclabel, monitoring_metricnotificationcheck'"
PROD "cd $DIR && docker-compose up -d"
```

- `monitoring_metricnotificationcheck` (0 righe) va inclusa: ha un vincolo verso `monitoring_metriclabel`. Senza di lei la `TRUNCATE` fallisce, ma in sicurezza perché è dentro una transazione.
- `DELETE … expire_date < now()` equivale a `manage.py clearsessions` con il backend su DB.

Poi si ripetono lo smoke test e l'inventario: devono cambiare solo le tabelle `monitoring_*` e `django_session`. Infine si riapre il sito.

## A11. Chiusura

- Merge della PR `feat/upgrade-geonode-4.4.5` e tag `prod-4.4.5`.
- Cron di pulizia delle sessioni (§6 del piano).
- I backup a freddo e l'immagine `rollback-4.4.1` restano per almeno 30 giorni.

## Rollback (provato in locale: 2 min 47 s)

```bash
PROD "cd $DIR && CONFIRM=si COMPOSE=docker-compose ENV_FILE=.env DUMPS=/opt/projects/geonode441/backup/$DAY bash -s" < scripts/rollback.sh
```

- Rinomina `geonode` e `geonode_data` in `*_failed_445_<timestamp>`, senza cancellarli, e li ripristina dal backup a freddo. Vanno ripristinati **entrambi**, perché la 4.4.5 scrive le sue migrazioni anche in `geonode_data`.
- Rimette `GEONODE_BASE_IMAGE_VERSION=4.4.1`, dopo aver copiato il `.env`, e riavvia tutto.
- Dopo: inventario confrontato con `inventory-freeze` e smoke test. Atteso tutto OK, tranne il PUT CSS che torna a 502.

## Problemi noti emersi nella prova

| # | Problema | Già presente in 4.4.1? | Impatto | Gestione |
|---|---|---|---|---|
| 1 | Dopo un salvataggio di stile riuscito, GeoNode (`set_styles`) **toglie dall'elenco degli stili alternativi del dataset** quelli nello stesso workspace del default: in `helpers.py` c'è `and` invece di `or` | Sì, il codice è identico (anche nel `master` di GeoNode). In 4.4.1 non si notava perché il salvataggio falliva prima | Basso | **Corretto** con la patch `set-styles-alt-workspace` ([app/patches](app/patches/README.md)), provata in locale: il dataset 570 mantiene i suoi 2 stili |
| 2 | Al primo salvataggio di stile dopo un riavvio, GeoServer può rispondere "DataSource not available after calling dispose()" a una richiesta concomitante sullo store `geonode_data` | Non verificabile in 4.4.1 (il salvataggio falliva) | Basso: osservato 2 volte, la richiesta successiva riesce | Lo smoke test riprova una volta e lo segnala |
| 3 | L'harvester di `ide.cime.es` (tipo GeoNode) fallisce il controllo di disponibilità ogni 10 minuti | Sì: 1.184 errori nelle 24 ore precedenti | Solo rumore nei log | Fuori perimetro |
| 4 | 5 thumbnail con URL malformati nel DB danno 404 | Sì, identiche | Estetico | Elenco di riferimento per lo smoke test |
| 5 | `pyopenssl 24.1.0` (residuo della 4.4.1) dichiara incompatibile `cryptography 45` | — | Nessuno: importazione e uso verificati, nessun pacchetto lo richiede | Nessuna azione |
| 6 | Cambiando il `.env` si ricrea anche il container `db` | — | Nessuno (dati nel volume) | Riavvio completo e ordinato in A8 |
