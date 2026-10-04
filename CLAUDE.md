# geonode.dh.unica.it: istruzioni per Claude Code

Configurazione di produzione e strumenti di manutenzione di geonode.dh.unica.it, il GeoNode del Centro DH UNICA.

**All'inizio di ogni sessione leggi [PROSSIMI-PASSI.md](PROSSIMI-PASSI.md)**: contiene lo stato attuale e cosa manca. A fine lavoro aggiornalo.

## Contesto

- Produzione su server dedicato `90.147.144.173`, utente `dhlake`. SSH: `ssh -o IdentitiesOnly=yes -i ~/.ssh/id_rsa dhlake@90.147.144.173` (senza `IdentitiesOnly` il server rifiuta per troppi tentativi). Non sta dietro il reverse proxy `proxy.dh.unica`.
- Progetto in produzione: `/opt/projects/geonode441/uni-cagliari-geonode`, con `docker-compose` v1 e `COMPOSE_PROJECT_NAME=uni_cagliari`.
- Documenti: [PIANO-AGGIORNAMENTO.md](PIANO-AGGIORNAMENTO.md) (garanzie e fasi), [RUNBOOK-PRODUZIONE.md](RUNBOOK-PRODUZIONE.md) (procedura eseguita, tempi, esito), [app/patches/README.md](app/patches/README.md) (correzioni locali a GeoNode).

## Regole

- **Nessuna modifica alla produzione senza un ok esplicito.** Le letture vanno bene.
- Ogni cosa si prova prima sulla **copia locale isolata** (`scripts/local.sh`, `scripts/local-browser.sh`), poi si verifica con `scripts/compare-inventory.py` e `scripts/smoke-test.py`.
- Comandi vietati (§5.2 del piano): `down -v`, `docker volume rm/prune`, `docker system prune`, `docker-purge.sh`, `docker rmi uni_cagliari/*`, `FORCE_REINIT=True`, build su prod, `DROP DATABASE` (si usa `ALTER DATABASE … RENAME`).
- **Mai stream da `docker run` senza `--log-driver none`.** Lo stdout finisce nel log del container sul disco: il 2026-10-04 ha riempito il disco di prod.
- Per i confronti usa `cmp`, `rtk proxy diff` o `scripts/compare-inventory.py`, non il `diff` riscritto dall'hook `rtk`, che ha dato esiti falsi.
- Git: mai commit su `main`. Un branch per attività (`feat/`, `fix/`, `docs/`, `chore/`), commit in italiano, poi PR, merge e cancellazione del branch. Tag `prod-<versione>` per ogni rilascio in produzione.
- Mai segreti nel repo: `app/.env` non è versionato, `app/.env.sample` ha i valori oscurati.
