# Patch locali a GeoNode

Correzioni al codice di GeoNode applicate durante la build dell'immagine da [`apply_patches.py`](apply_patches.py), che viene chiamato dal [`Dockerfile.4.4.5`](../Dockerfile.4.4.5).

Ogni patch sostituisce un frammento **esatto** di codice. Se a un aggiornamento il frammento non c'è più, **la build fallisce** e indica quale patch rivedere. Così nessuna correzione si perde in silenzio.

Ci sono due casi:

- **GeoNode ha corretto il difetto:** si toglie la patch da `apply_patches.py` e da questa tabella.
- **Il difetto c'è ancora:** si adatta il frammento al nuovo codice e si riprova in locale (vedi lo smoke test e il test qui sotto).

| ID | File | Problema | Introdotta | Verifica |
|---|---|---|---|---|
| `set-styles-alt-workspace` | `geonode/geoserver/helpers.py`, `set_styles()` | La condizione sugli stili alternativi usa `and` invece di `or` (`name != default.name and workspace != default.workspace`). Uno stile alternativo nello **stesso workspace** dello stile di default viene scartato. Ogni volta che si salva uno stile, GeoNode toglie dal dataset gli stili alternativi; restano in GeoServer ma spariscono dall'elenco in GeoNode. Il difetto è presente in 4.4.1, in 4.4.5 e nel `master` di GeoNode al 2026-10-04 | 2026-10-04, upgrade a 4.4.5 | In locale: salvare lo stile CSS di un dataset con 2 stili (es. il 570) e controllare che `layers_dataset_styles` non perda righe |
