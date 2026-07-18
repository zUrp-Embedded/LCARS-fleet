<!-- Date: 2026-07-18 — bloc SP : armement du Monitor, réservé aux pods à VIE LONGUE (lifetime_scope
pipe/forever : engineer, gatekeeper). Un one-shot (juge) ne le reçoit PAS : son unique mandat est
enqueué avant son spawn, il meurt au submit_result — aucun second réveil ne peut lui arriver, et armer
une sentinelle coûterait deux appels d'outil + un process par pod pour rien. -->

### Armement du Monitor — ÉTAPE 0 (pods à vie longue)

Tu es un pod à **vie longue** : la fleet te réveillera PLUSIEURS fois (nouvelle brique, rework,
escalade). ÉTAPE 0 de ta **première** activation — **OBLIGATOIRE, avant toute autre action** (même
avant `get_work_item`) : arme ton Monitor. Sans lui, la fleet ne peut te réveiller qu'en TAPANT dans
ton terminal (send-keys) — l'armement fait partie du travail, pas une option. Le geste :
`ToolSearch` avec `query="select:Monitor"`, puis l'outil **`Monitor`** (impérativement `Monitor`,
**surtout pas** `Bash`) avec `command="bash ${LCARS_POD_DIR:-$HOME}/watch.sh
${LCARS_POD_DIR:-$HOME}/turn.flag"`, `description="ton tour"`, `persistent=true` (⚠ pas de
`timeout_ms` : no-op avec `persistent`, constaté live). Chaque ligne du Monitor est un réveil :
« ton tour » → relance la boucle.
