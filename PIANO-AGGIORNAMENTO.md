# Piano di aggiornamento GeoNode — geonode.dh.unica.it

Stato: **v2, in attesa di approvazione finale** · Redatto: 2026-10-04 · Responsabile: Alessandro Capra

## 0. Decisioni prese (2026-10-04)

| # | Decisione |
|---|---|
| 1 | Repository git **privato** `github.com/dh-unica/geonode.dh.unica.it` (account `caprowsky`, admin dell'organizzazione) |
| 2 | **Fase A: solo 4.4.1 → 4.4.5**, oggi. La fase B (→ 5.x) è un intervento successivo e separato (§10) |
| 3 | Pulizia di tabelle di monitoring e sessioni scadute, più una pulizia periodica documentata (§6) |
| 4 | Finestra di manutenzione: **oggi**. L'avviso agli utenti lo dà Alessandro |
| 5 | Cache GeoWebCache (5,8 GB) **non copiata**: si rigenera da sola. Spazio locale da risparmiare |
| 6 | Sezione dedicata a "nessun dato perso e ritorno garantito" (§5) |

Obiettivo della fase A: risolvere il 502 sul salvataggio degli stili CSS. La causa è `geoserver-restconfig 2.0.12` ([GeoNode #12716](https://github.com/GeoNode/geonode/issues/12716)), corretto in 2.0.14, che è incluso in GeoNode 4.4.5. Il tutto **cambiando il minimo indispensabile**.

---

## 1. Inventario della produzione (rilevato in sola lettura)

| Voce | Valore |
|---|---|
| Server | `90.147.144.173` (`dhlake`), Ubuntu 20.04.3, 4 vCPU, 7,8 GB RAM (~600 MB liberi), disco **48 GB liberi** su 225 |
| Docker | Engine 20.10.12, **`docker-compose` 1.27.3** (v1). `docker compose` v2 non presente. `sudo` richiede password |
| Progetto | `/opt/projects/geonode441/uni-cagliari-geonode` (geonode-project `uni_cagliari`, remote GeoSolutions non accessibile) |
| `COMPOSE_PROJECT_NAME` | `uni_cagliari` |
| Immagini in uso | `uni_cagliari/geonode:4.4.1` (`de3ab4bb718e`, 2,48 GB), `geoserver:2.24.4-v1`, `geoserver_data:2.24.4-v1`, `postgis:15.3-latest`, `nginx:1.25.3-latest`, `letsencrypt:2.6.0-latest`, `rabbitmq:3-alpine`, `memcached:alpine` |
| Personalizzazioni | `templates/geonode-mapstore-client/_geonode_config.html`, `management/commands/fixup_missing_maplayers.py` |
| Contenuti | 319 dataset, 52 mappe, 36 documenti, 5 geostory, 1 mapviewer, 16 servizi remoti, 22 utenti |
| Backup esistenti | uno solo, `backup/backup_restore/2024-11-25_165657.zip` (14 GB, nov 2024). Nessun backup schedulato |

### Volumi

| Volume | Dim. | Contenuto |
|---|---|---|
| `uni_cagliari-dbdata` | 4,7 GB | DB `geonode` 3,7 GB (di cui ~3,6 GB monitoring + sessioni), `geonode_data` 637 MB (dati vettoriali PostGIS) |
| `uni_cagliari-statics` | 33,4 GB | `assets_data/` 21 GB, `uploaded/` 5,7 GB, `uploaded.zip` 4,4 GB, `static/` 238 MB (rigenerato a ogni avvio), **`geonode_init.lock`** |
| `uni_cagliari-gsdatadir` | 6,1 GB | data dir GeoServer: `gwc/` 5,8 GB (cache), `workspaces/`, `styles/`, `security/`, `geofence/`, `data/` 289 MB, `logs/` |
| `uni_cagliari-nginxcerts` / `-nginxconfd` | <100 kB | certificati Let's Encrypt e conf nginx |
| `-rabbitmq`, `-tmp`, `-data`, `-dbbackups`, `-backup-restore` | ~0 | — |

### Cosa esegue il container Django a ogni avvio (`src/entrypoint.sh`)

1. `invoke migrations`: `migrate` su `geonode` e su `datastore` (`geonode_data`). **Modifica lo schema del DB.**
2. `invoke prepare`: scrive fixture in `/tmp` del container, senza caricarle.
3. **Solo se manca `/mnt/volumes/statics/geonode_init.lock`**: `loaddata` di admin di esempio, app OAuth e dati iniziali, cioè **sovrascrive password admin e client OAuth GeoServer**. ⚠️ Vedi §5.2.
4. `invoke statics`: `collectstatic` in `statics/static/` (rigenerabile).

---

## 2. Cosa cambia con 4.4.1 → 4.4.5 (perimetro esatto)

| Componente | Cambia? | Dettaglio |
|---|---|---|
| Immagine Django/Celery | **Sì** | `GeoNode==4.4.5` (oggi `~=4.4.1`, che a una nuova build installerebbe comunque l'ultima 4.4.x: va bloccata la versione esatta). Django 4.2.9 → 4.2.29, `geoserver-restconfig` 2.0.14, `django-geonode-mapstore-client` 4.4.5, `geonode-importer` 1.1.4 |
| Schema DB `geonode` | **Sì, minimo** | Due migrazioni nuove: `base.0093_alter_thesaurus_slug`, `base.0094_fix_otherrestrictions_codetype`. Una modificata: `documents.0037` (già applicata) |
| DB `geonode_data` (dati vettoriali) | No | Nessuna migrazione prevista; verificato a posteriori |
| GeoServer, data dir GeoServer | **No** | Restiamo volutamente su `2.24.4-v1`. Il template 4.4.x proporrebbe 2.27.4: è rimandato alla fase B |
| PostGIS, nginx, letsencrypt, rabbitmq, memcached | **No** | Stesse immagini |
| File utenti (`assets_data/`, `uploaded/`) | **No** | Nessun comando li tocca. `migrate_file_to_assets` è **escluso** da questa fase |
| `statics/static/` | Sì | Rigenerato da `collectstatic` |
| `docker-compose.yml` | No (salvo diff minimo) | Stessi servizi, volumi e nomi container |

Quindi in questa fase l'aggiornamento modifica in modo non rigenerabile **solo il DB `geonode`**: 2 migrazioni più la pulizia (§6). È lì che si concentrano backup e rollback.

---

## 3. Repository git e cartella locale

```text
geonode.dh.unica.it/                  ← repo git → github.com/dh-unica/geonode.dh.unica.it (privato)
├── PIANO-AGGIORNAMENTO.md
├── RUNBOOK-PRODUZIONE.md             ← comandi esatti e tempi, prodotto dalla prova in locale
├── app/                              ← progetto (copia di /opt/projects/geonode441/uni-cagliari-geonode)
│   ├── .env.sample                   ← versionato, SENZA segreti
│   ├── .env                          ← NON versionato (prod)
│   └── .env.local                    ← NON versionato (locale)
├── overrides/docker-compose.local.yml
├── scripts/
│   ├── inventory.sh                  ← "fotografia" di prod/locale (conteggi, manifest file, checksum)
│   ├── backup-prod.sh                ← backup verso il locale
│   ├── restore-local.sh
│   ├── smoke-test.sh
│   └── rollback-prod.sh
└── backups/                          ← NON versionato
```

- `main` = ciò che gira in produzione. Primo commit = copia esatta di oggi → tag **`prod-4.4.1`**.
- Branch `feat/upgrade-geonode-4.4.5` → PR → merge dopo il go-live → tag **`prod-4.4.5`**.
- `.gitignore`: `.env*` (tranne `.env.sample`), `backups/`, `*.dump`, `*.tar*`.
- Prima del primo push si controlla con `git grep` che non ci siano password, `SECRET_KEY` o token nel repo.

---

## 4. Procedura (fase A, oggi)

| # | Passo | Dove | Downtime |
|---|---|---|---|
| A1 | Repo git + copia progetto + tag `prod-4.4.1` | locale | no |
| A2 | Backup "a caldo" di prod (§5.3) e inventario | prod→locale | no |
| A3 | Restore in locale e verifica di fedeltà: il 502 sugli stili CSS deve riprodursi (§5.4) | locale | no |
| A4 | Build immagine 4.4.5, upgrade in locale, test (§7), pulizia (§6), test di nuovo | locale | no |
| A5 | **Prova del rollback in locale** (§5.6) | locale | no |
| A6 | Runbook con tempi misurati | locale | no |
| A7 | Avviso utenti → **freeze** di prod → backup finale "a freddo" + verifica | prod | **sì** |
| A8 | Trasferimento su prod dell'immagine testata (`docker save`/`docker load`) e upgrade | prod | sì |
| A9 | Smoke test + confronto inventario prima/dopo (§5.5) → riapertura oppure rollback | prod | sì |
| A10 | Pulizia tabelle (§6) + `VACUUM FULL` | prod | sì (breve) |
| A11 | Merge, tag `prod-4.4.5`, cron di pulizia e backup periodico | prod | no |

Downtime stimato: 45–90 min (verrà misurato in A6).

---

## 5. Garanzie: nessun dato perso, ritorno sempre possibile

### 5.1 Principi (non negoziabili)

1. **Niente operazioni distruttive senza un backup verificato.** "Verificato" vuol dire *ripristinato davvero e confrontato*, non solo "il file esiste".
2. **Almeno due copie su due macchine diverse** di tutto ciò che non è rigenerabile, prima di modificare la produzione.
3. **Lo stato precedente non si sovrascrive mai, si affianca:** vecchia cartella di progetto intatta, vecchie immagini taggate e salvate su file, DB fallito rinominato e non cancellato.
4. **In produzione si installa esattamente ciò che è stato testato:** l'immagine si costruisce una volta in locale e si trasferisce per digest. Su prod non si ricostruisce niente, perché `geonode-base:latest-ubuntu-22.04` è un tag mobile.
5. **Ogni passo ha un controllo con esito binario** (OK/KO) e si va avanti solo con OK.
6. **Il rollback si prova in locale prima di averne bisogno.**
7. **L'ambiente locale non deve mai poter parlare con la produzione.**

### 5.2 Comandi e azioni vietati durante tutta l'attività

| Vietato | Perché |
|---|---|
| `docker-compose down -v` / `docker volume rm` / `docker volume prune` / `docker system prune` | cancellano i volumi con DB e file utenti |
| `./docker-purge.sh` (presente nel progetto) | fa pulizia aggressiva di container, immagini e volumi |
| `docker image prune` / `docker rmi` su `uni_cagliari/*` | eliminano l'immagine di rollback |
| Avviare Django con un volume statics **senza** `geonode_init.lock` | ricarica i fixture: reset della password admin e del client OAuth di GeoServer |
| `FORCE_REINIT=True` nel `.env` | stesso effetto del punto precedente |
| Ricostruire l'immagine su prod (`docker-compose build`) | si otterrebbe un'immagine diversa da quella testata |
| `DROP DATABASE` | si usa sempre `ALTER DATABASE … RENAME` (§5.6) |
| `migrate_file_to_assets`, upgrade GeoServer/PostGIS | fuori perimetro della fase A |
| Avviare lo stack locale senza `extra_hosts` (§5.4) | il locale potrebbe scrivere sulla produzione |

### 5.3 Backup: cosa, come, dove, come si verifica

#### Elenco completo dello stato da salvare

| Elemento | Rigenerabile? | Metodo | Copia 1 | Copia 2 |
|---|---|---|---|---|
| DB `geonode` | no | `pg_dump -Fc` | prod `/opt/projects/geonode441/backup/2026-10-04/` | locale `backups/2026-10-04/` |
| DB `geonode_data` | no | `pg_dump -Fc` | prod | locale |
| Ruoli e permessi PostgreSQL | no | `pg_dumpall --globals-only` | prod | locale |
| Volume `dbdata` intero | — | resta intatto finché non c'è il go/no-go; nessuna operazione lo cancella | volume | — |
| `statics/assets_data/`, `uploaded/`, `uploaded.zip`, `geonode_init.lock` | no | tar in streaming da container `:ro` → estratto in locale | **volume prod (non toccato dall'upgrade)** | locale |
| Data dir GeoServer **senza `gwc/`** | no | tar da container `:ro` | prod (~300 MB) | locale |
| `nginxcerts`, `nginxconfd` | sì, ma scomodo | tar | prod | locale |
| `.env`, `docker-compose.yml`, `src/` | no | copia + git | cartella `geonode441` (intatta) | git (senza segreti) + locale |
| Immagine `uni_cagliari/geonode:4.4.1` (`de3ab4bb718e`) | **no** (base mobile) | `docker tag …:rollback-4.4.1` + `docker save \| gzip` | prod (immagine + file .tar.gz) | locale (file) |
| Code RabbitMQ | — | si svuotano prima del freeze (`rabbitmqctl list_queues` = 0, oggi c'è 1 messaggio in `celery`) | — | — |
| Cache GWC, `statics/static/`, log | sì | non salvati | — | — |

#### Modalità

- **Backup a caldo (A2)**, senza downtime: serve per la prova in locale. I dump sono consistenti al loro interno (`pg_dump` usa uno snapshot transazionale).
- **Backup a freddo (A7)**, durante il freeze: è quello che vale per il rollback.
  1. `docker-compose stop geonode django celery` (nginx, Django e Celery: da qui nessuno scrive).
  2. Controllo che le code RabbitMQ siano a 0.
  3. Con `db` e `geoserver` ancora attivi: `pg_dumpall --globals-only`, `pg_dump -Fc geonode`, `pg_dump -Fc geonode_data`.
  4. `docker-compose stop geoserver`, poi tar della data dir da container `alpine` con mount `:ro`.
  5. Statics: GeoNode e GeoServer sono fermi, quindi i file sono stabili. Si aggiorna la copia locale (tar della sola differenza calcolata sul manifest, §5.5) e si rifà il manifest.
- I backup **non vengono scritti sul disco di prod oltre ~4 GB** (dump + data dir + immagine). La copia degli statics è solo in locale: lo spazio su prod (48 GB) non basta per duplicarli e comunque non vengono toccati.

#### Verifiche del backup (tutte devono dare OK)

1. `sha256sum` di ogni file su prod, ricalcolato dopo il trasferimento in locale: identico.
2. `pg_restore --list` di ogni dump: nessun errore, numero di oggetti atteso.
3. **Restore reale** in locale: i conteggi riga per riga di **tutte** le tabelle di `geonode` e `geonode_data` coincidono con quelli presi su prod nello stesso momento (`scripts/inventory.sh`).
4. Manifest dei file (`percorso, dimensione, mtime`) di statics e data dir: prod e locale coincidono (`diff` vuoto).
5. Immagine salvata: `docker load` in locale, l'ID coincide con `de3ab4bb718e`.

### 5.4 La copia locale è fedele e isolata

- **Fedeltà**: stesso hostname, stesse immagini, stessi volumi ripristinati. `/etc/hosts` dell'host **non si tocca**: i test manuali si fanno da una finestra Chrome dedicata (`scripts/local-browser.sh`: profilo temporaneo e `--host-resolver-rules` solo per quella istanza), i test automatici con `curl --resolve` / Playwright con la stessa regola. Il resto del sistema continua a vedere la produzione. Prova: il bug del 502 sugli stili CSS si riproduce. Se non si riproduce, la copia non è fedele e ci si ferma.
- **Isolamento dalla produzione** (critico: con lo stesso hostname i container locali potrebbero risolvere `geonode.dh.unica.it` verso il **server vero** e scriverci sopra):
  - `extra_hosts: geonode.dh.unica.it:host-gateway` su django, celery e geoserver nel `docker-compose.local.yml`;
  - controllo prima di ogni avvio: `getent hosts geonode.dh.unica.it` dentro ogni container deve dare un IP **locale**;
  - harvesting/probe dei 16 servizi remoti disattivato, email già disattivata;
  - durante la finestra di manutenzione lo stack locale resta **spento** mentre si lavora sulla produzione.
- **Spazio locale**: il volume statics locale è un **overlay** sul backup. Il backup è la parte di sola lettura, le scritture dei test finiscono in un livello separato. Così il backup resta immutabile e non si duplicano 31 GB. Totale stimato ~40 GB su 109 liberi.

### 5.5 Prova che dopo l'upgrade non manca niente (prima di riaprire)

`scripts/inventory.sh` gira su prod **prima** del freeze, **dopo** il backup a freddo e **dopo** l'upgrade. I risultati si confrontano con `diff`:

| Controllo | Esito atteso |
|---|---|
| Conteggio righe per **ogni** tabella di `geonode` (escluse `monitoring_*`, `django_session`, `django_celery_*`) | identico |
| Conteggio righe per ogni tabella di `geonode_data` | identico |
| `base_resourcebase` per `resource_type`; utenti; gruppi; permessi (`guardian_*`) | identico |
| Elenco layer, stili e workspace da REST GeoServer | identico |
| Manifest file di `assets_data/`, `uploaded/` | identico (`diff` vuoto) |
| Manifest data dir GeoServer (escluse `gwc/` e `logs/`) | identico, salvo file che GeoServer riscrive all'avvio (elencati e motivati nel runbook dopo la prova locale) |
| `geonode_init.lock` presente | sì |
| Migrazioni applicate | stesse di prima più `base.0093` e `base.0094` |

Poi gli smoke test (§7). Si riapre solo se tutto è OK.

### 5.6 Rollback

**Quando**: se un controllo di §5.5 o uno smoke test essenziale (§7) dà KO e non si risolve entro **30 minuti** dall'avvio della nuova versione. Dopo il rollback si rifanno i controlli di §5.5 contro l'inventario di partenza.

**Come** (`scripts/rollback-prod.sh`, provato in locale in A5):

1. `docker-compose stop django celery geonode`.
2. **DB, senza distruggere nulla**:

   ```sql
   ALTER DATABASE geonode RENAME TO geonode_failed_445;
   CREATE DATABASE geonode OWNER geonode;
   ```

   poi `pg_restore` dal dump a freddo e verifica dei conteggi con §5.5. **Lo stesso vale per `geonode_data`**: la prova ha mostrato che la 4.4.5 registra le sue 3 migrazioni anche lì (`django_migrations` +3), quindi si ripristinano sempre entrambi. I DB "falliti" restano disponibili per l'analisi e si cancellano solo a stabilità raggiunta. Procedura e tempi in [RUNBOOK-PRODUZIONE.md](RUNBOOK-PRODUZIONE.md) (`scripts/rollback.sh`, 2 min 47 s in locale).

3. **Immagine**: in `.env` si rimette `GEONODE_BASE_IMAGE_VERSION=4.4.1`. L'immagine `de3ab4bb718e` è ancora sul server; in caso contrario si fa `docker load` dal file salvato.
4. **Codice/compose**: si torna alla cartella `/opt/projects/geonode441/uni-cagliari-geonode`, mai modificata.
5. **Data dir GeoServer**: non prevista modifica in fase A. Se l'inventario mostra differenze inattese: stop geoserver, la data dir attuale si sposta in `_failed_445/` dentro lo stesso volume e si estrae il tar (escluso `gwc`).
6. **Statics**: i file utente non sono toccati. `static/` lo rigenera il 4.4.1 all'avvio.
7. `docker-compose up -d`, inventario, smoke test su 4.4.1.

Tempo stimato: 20–30 minuti (misurato in A5).

**Dopo la riapertura** gli utenti possono creare dati nuovi, e un rollback successivo li perderebbe. Per questo:

- i backup a freddo e l'immagine `rollback-4.4.1` si tengono **almeno 30 giorni**;
- nelle prime 48 ore, se emerge un problema grave, prima di qualsiasi rollback si fa un nuovo dump. I dati creati dopo l'upgrade si reimportano a mano.

### 5.7 Punto di non ritorno

In fase A **non esiste un passo irreversibile**: il DB precedente è nel dump (2 copie) e i file utente non vengono toccati. L'unico passo con effetto permanente è la pulizia delle tabelle (§6). Si esegue **dopo** l'esito positivo dei controlli e i dati eliminati restano comunque nel dump a freddo.

---

## 6. Pulizia del database

### Cosa dice la documentazione

- **Sessioni** (`django_session`, 3,61 milioni di righe, **3,57 milioni scadute**, dal 2022): Django non cancella da solo le sessioni scadute. La [documentazione Django](https://docs.djangoproject.com/en/4.2/topics/http/sessions/#clearing-the-session-store) prescrive di eseguire **`manage.py clearsessions` periodicamente, per esempio con un cron giornaliero**. In questa installazione non è mai stato fatto.
- **Monitoring** (`monitoring_*`, ~2,2 GB, 8,2 milioni di righe in `monitoring_metricvalue`):
  - GeoNode cancella i dati più vecchi di `MONITORING_DATA_TTL` (365 giorni) **solo dentro il task `collect_metrics`**, che gira solo con `MONITORING_ENABLED=True`;
  - qui il monitoring è **disattivato** e i dati sono fermi al **14/11/2024** (residuo dell'installazione precedente), quindi nessuno li cancellerà mai;
  - in GeoNode 5.0 l'app `monitoring` è **rimossa**, per cui questi dati non serviranno più.
- **Risultati Celery** (`django_celery_results_taskresult`, 15 MB): li pulisce il task di beat `celery.backend_cleanup`. Va verificato che beat giri davvero: lo scheduler è il `PersistentScheduler` su file e nel DB l'ultima esecuzione risulta 2024-11-14.

### Pulizia una tantum (A10, dopo l'esito positivo, dati comunque nel dump a freddo)

```sql
-- solo tabelle di dati; restano le tabelle di configurazione (metric, servicetype, eventtype…)
TRUNCATE monitoring_metricvalue, monitoring_requestevent_resources,
         monitoring_requestevent, monitoring_exceptionevent, monitoring_metriclabel,
         monitoring_metricnotificationcheck;  -- 0 righe, ma referenzia metriclabel (emerso nella prova)
```

```bash
python manage.py clearsessions
```

Poi `VACUUM FULL` delle tabelle pulite (per restituire spazio al disco, ~3,5 GB). Si fa a sito fermo perché blocca le tabelle. Effetto atteso: DB `geonode` da 3,7 GB a ~0,2 GB.

### Pulizia periodica (A11)

- Cron sull'host, ogni giorno alle 03:30: `docker exec django4uni_cagliari python manage.py clearsessions`.
- Monitoring: nessuna azione periodica, resta disattivato (e sparisce in 5.0).
- Log uwsgi `/var/log/geonode.log` (~940 MB, non ruotato): `logrotate` sull'host oppure `log-maxsize` in `uwsgi.ini`.

---

## 7. Test di accettazione (in locale in A4, in produzione in A9)

Automatici (`scripts/smoke-test.sh`):

- [ ] Homepage, `/catalogue/`, `/api/v2/resources`: conteggi per tipo = inventario.
- [ ] Login admin; login OAuth2 su `/geoserver/web/`.
- [ ] WMS/WFS/WCS GetCapabilities; GetMap PNG su 10 layer campione (vettoriali e raster), immagine non vuota; GetLegendGraphic.
- [ ] Lettura REST via `/gs/rest/…` (stili e layer).
- [ ] **PUT stile CSS `?raw=true` sul dataset 570 → 200** (il bug di partenza), con contenuto identico.
- [ ] Download di un dataset e di un documento.
- [ ] Thumbnail di tutte le risorse → HTTP 200.

Manuali:

- [ ] Apertura di 3 mappe e 1 geostory.
- [ ] Modifica di uno stile dall'editor visuale e da quello di codice, poi ripristino.
- [ ] Upload di un dataset di prova (shapefile), modifica metadati e permessi, cancellazione.
- [ ] Un task Celery completato (log `celery4uni_cagliari`).

---

## 8. Rischi della fase A

| Rischio | Prob. | Impatto | Mitigazione |
|---|---|---|---|
| L'immagine 4.4.5 non parte con `src/` e `settings.py` attuali | Bassa | Medio | Si scopre in A4; correzioni nel branch prima di toccare prod |
| Le migrazioni 0093/0094 falliscono su dati reali (thesaurus) | Bassa | Medio | Provate su copia reale (A4); rollback DB provato (A5) |
| Avvio senza `geonode_init.lock` → reset admin e OAuth | Bassa | Alto | Verifica esplicita prima di ogni avvio (§5.2) |
| Il locale scrive sulla produzione | Bassa | Alto | `extra_hosts` + verifica `getent` (§5.4) |
| Spazio disco su prod (immagine nuova ~2,5 GB + dump ~4 GB) | Bassa | Medio | 48 GB liberi; `VACUUM FULL` ne recupera ~3,5 |
| `docker-compose` 1.27.3 non interpreta qualcosa del compose aggiornato | Bassa | Medio | In fase A il compose resta quello attuale |
| Banda prod→locale lenta per i 31 GB di statics | Media | Basso | Il backup a caldo parte per primo; a freddo si trasferisce solo la differenza |
| **Avvenuto il 2026-10-04 (~16:15–16:20 UTC):** lo stream degli statics da `docker run` è finito anche nel log json del container e ha riempito il disco di prod (sito in errore per circa 5 minuti, PostgreSQL in crash recovery) | — | Alto | Container rimosso, spazio tornato a 48 GB, inventario identico a quello precedente: **nessun dato perso**. Ora tutti i container usano `--log-driver none`, e un watchdog interrompe il backup sotto i 20 GB liberi |

---

## 9. Dopo la fase A

- Backup schedulato: dump giornaliero dei DB + copia settimanale di statics e data dir **fuori dal server**.
- Revisione della memoria: GeoServer `-Xmx4G` + uwsgi fino a 128 processi su 7,8 GB.
- Porta `8080` di GeoServer esposta direttamente su Internet (`ports: 8080:8080` nel compose): valutare la chiusura, si passa già da nginx.
- Rotazione delle credenziali passate in chat (admin GeoNode, SSH `dhlake`).
- Emerso in A1: `SECRET_KEY` e client OAuth2 GeoNode↔GeoServer (`OAUTH2_CLIENT_ID`/`SECRET`) sono **i default pubblici del template** geonode-project; anche le password DB sono i default (`geonode`/`geonode_data`). Da rigenerare (il client OAuth va aggiornato sia in GeoNode sia nella config OAuth di GeoServer).

## 10. Fase B (successiva, da pianificare): 4.4.5 → 5.0.3 → 5.1.0

In sintesi, da dettagliare con la stessa disciplina di §5:

- Redis al posto di RabbitMQ (breaking change), Ubuntu 24.04, Python 3.12, Django 5, importer nel core;
- GeoServer 2.27 → 2.28 (la data dir **non torna indietro**: backup completo obbligatorio), regole aggiuntive in `rest.properties`;
- PostGIS 3.5 (`ALTER EXTENSION postgis UPDATE`), `migrate_file_to_assets`, porting delle personalizzazioni;
- compose v2 da installare sul server.

Riferimento: [Upgrade from GeoNode 4 to 5](https://github.com/GeoNode/geonode/wiki/Upgrade-from-GeoNode-4-to-5).
