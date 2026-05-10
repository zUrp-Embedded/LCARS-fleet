# PoC-04 — event log NDJSON concurrent + logrotate

**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : done — 4/4 PASS, hypothèse validée
**Référencé par** : `work/beyond/poc-plan.md §PoC-04`
**Branche** : `feature/poc-04-ndjson-logrotate`

## Hypothèse

Sous ext4, deux processes qui écrivent en `O_APPEND + fsync` sur le même fichier NDJSON produisent un stream atomique par ligne (pas d'interleaving de chars, pas de ligne coupée). La rotation par `rename + touch + SIGHUP` (équivalent logrotate `create` + `postrotate: kill -HUP`) permet aux writers de rouvrir le FD sur le nouveau fichier sans perte, et un `stream.meta` peut être écrit par le postrotate script sans race.

Garantie attendue : le contrat d'event log LCARS (une seule source de vérité, NDJSON append-only, rotations fréquentes) tient sous stress concurrent.

## Méthode

3 scripts :

- `writer.py` — writer Python. Ouvre le fichier avec `O_APPEND | O_CREAT`, écrit N lignes `{"writer": ..., "seq": ..., "ts_ns": ...}`, fsync après chaque ligne. Gère `SIGHUP` → close + reopen du FD (pattern logrotate).
- `test_ndjson.sh` — orchestrateur. Lance 2 writers en parallèle (1000 lignes chacun, 2ms d'intervalle). À 1s, `mv events.ndjson events.ndjson.1 && touch events.ndjson && kill -HUP <writers>`. Écrit `events.ndjson.1.meta` comme postrotate hook.
- `verify.py` — vérificateur. Lit rotated + active dans l'ordre, vérifie : chaque ligne parse en JSON, chaque writer a seq 0..N-1 complet sans gap ni doublon, ordre monotone par writer (dans un file et à la transition entre files).

## Résultats

| Test | Vérification | PASS |
|---|---|---|
| T1 | integrité (pas de perte, ordering, pas de ligne coupée) | PASS |
| T2 | `stream.meta` écrit par postrotate, JSON valide | PASS |
| T3 | chaque ligne parse en JSON (2000/2000) | PASS |
| T4 | writers ont écrit dans rotated ET active → reopen correct après SIGHUP | PASS |

Chiffres d'une exécution :
- W1 : 285 lignes dans rotated, 715 dans active, total 1000
- W2 : 284 lignes dans rotated, 716 dans active, total 1000
- 2000/2000 JSON valides, 0 invalid, 0 seq missing, 0 dupe, 0 order violation
- rotation capturée à ~28% du run

## Conclusion

Hypothèse validée. `O_APPEND` sous ext4 garantit l'atomicité ligne-entière tant que `len(line) < PIPE_BUF` (4096 bytes sur Linux) — largement suffisant pour des events NDJSON LCARS typiques. La rotation `rename + touch + SIGHUP` est le pattern correct ; les writers reopen proprement leur FD et continuent sans perte. Le postrotate script peut écrire `stream.meta` sans race avec les writers actifs (il opère sur l'ancien nom du fichier, les writers opèrent maintenant sur le nouveau FD).

Pas de finding. Chemin libre pour implémentation event log LCARS B2 (ring log rotation).

## Notes d'implémentation pour le runtime

- **Ligne > 4KB** : casse l'atomicité. Pattern défensif — si un payload event est gros (stack trace, output capture), le chunker et émettre plusieurs events liés par `event_id` plutôt qu'une ligne unique.
- **fsync par ligne** : coût IO réel sur SSD de ~1ms par ligne (ici non mesuré mais observable). Pour un event-log avec N writers × 100 lignes/s, prévoir impact IOPS. Alternative : `fdatasync` tous les 10 events + fsync périodique si la throughput devient critique. Trade-off vs garantie crash-recovery à instruire en FMEA.
- **logrotate config réelle** : `copytruncate` est **à proscrire** — il réécrit le même inode, les writers continuent d'écrire dans le (nouveau) début du fichier. Utiliser `create 0644` + `postrotate: pkill -HUP fleet-pilot` (ou l'équivalent par-worker). Le PoC réplique cette séquence en pur bash pour éviter la dépendance logrotate system-wide.
- **meta file** : `stream.meta` doit être écrit APRÈS le rename (le fichier rotated est alors gelé). Le fichier actif reste ouvert par les writers, pas d'écriture concurrente sur le meta.

## Livrables

- `writer.py`, `verify.py`, `test_ndjson.sh` — harness reproductible

## Hors scope

- Test sur `drvfs` (systèmes Windows-via-WSL) — le event log LCARS vit en `/var/lib/fleet/` ext4, pas drvfs. PoC-12 couvre drvfs round-trip.
- Test crash writer en cours d'écriture — un writer killé en plein `write` laisse peut-être une ligne partielle si `len > PIPE_BUF`. Hors scope ici ; si besoin, ajouter un scanner qui skip silencieusement les lignes invalides en fin de file (déjà fait dans verify.py).
- Mesure throughput/latence — ce PoC est un test de correctness, pas de perf. PoC spécifique à prévoir si budget permet.
