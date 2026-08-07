# FMEA — CC Runtime Hooks

**Date** : 2026-03-28
**Derniere revision** : 2026-03-28
**Statut** : en cours — post-scope-check.sh fait, pre-compact-harvest.sh a faire
**Reference par** : work/TODO/v6-rings-and-interfaces.md
**Derive de** : —

Analyse FMEA des hooks Claude Code (.claude/hooks/).
Methode : par script, severite 1-10, occurrence 1-10, detection 1-10, RPN = S x O x D.
Mitigation obligatoire si RPN > 10.

---

## post-scope-check.sh

| # | Mode de defaillance | Cause | Effet | S | O | D | RPN | Mitigation |
|---|---|---|---|---|---|---|---|---|
| PSC-01 | jq absent au runtime | Environnement mal provisionne | Hook silencieusement desactive — aucune detection de scope violation | 7 | 1 | 2 | 14 | FAIT: dependency check `command -v jq` avec message explicite en sortie |
| PSC-02 | stdin vide ou JSON malformed | Claude Code change de format, bug runtime | FILE_PATH vide, hook sort silencieusement — faux negatif | 5 | 2 | 3 | 30 | FAIT: exit early sur stdin vide + jq `// empty` fallback. RISQUE RESIDUEL: si CC change le schema JSON (tool_input renomme), detection impossible sans test d'integration |
| PSC-03 | CLAUDE_AGENT_NAME non defini et instance-name absent | Agent non provisionne, fresh install | INSTANCE="unknown", aucun scope check (case fallthrough) — faux negatif | 6 | 2 | 2 | 24 | FAIT: fallback chain (env var -> fichier -> "unknown") + warning stderr quand INSTANCE="unknown". Test: "warns on unknown instance identity" |
| PSC-04 | Scope rules divergent des directives SP | Modification SP sans update hook | Hook autorise ce que le SP interdit, ou bloque ce qu'il autorise | 8 | 3 | 5 | 120 | MITIGE: commentaires referencent les sections SP. TODO: test d'integration qui parse le SP et verifie la coherence (v7) |
| PSC-05 | Nouveau role d'agent non couvert dans le case | Ajout d'un agent dans fleet.yaml sans update hook | Agent non reconnu = aucun scope check (fallthrough) — faux negatif | 6 | 3 | 2 | 36 | FAIT: case `*` emet un warning stderr "unrecognized instance". Test: "warns on unrecognized instance name". RISQUE RESIDUEL: le warning va en stderr, pas dans le contexte Claude — a migrer vers stdout si on veut que l'agent reagisse |
| PSC-06 | Race condition : hook execute apres write reussi (PostToolUse) | Design inherent — c'est un PostToolUse, pas PreToolUse | La violation est detectee APRES le dommage — le fichier est deja ecrit | 4 | 10 | 1 | 40 | ACCEPTE: by design. Le hook revele (GO-3), la correction est manuelle. Migrer vers PreToolUse bloquerait les outils — risque de side-effects pire que le probleme |
| PSC-07 | Log file inaccessible (permissions, disk full) | Probleme systeme | Violation non loguee, seul le stdout dans le contexte Claude persiste | 3 | 1 | 3 | 9 | RPN < 10 — accepte. Le stdout est le canal primaire, le log est secondaire |
| PSC-08 | Paths avec espaces ou caracteres speciaux | Noms de fichiers exotiques | Pattern matching rate, faux negatif ou faux positif | 4 | 1 | 4 | 16 | MITIGE: toutes les variables sont quotees. Les patterns glob `==` gerent les espaces correctement en bash |

### Bilan post-scope-check.sh

- 8 modes analyses
- RPN max apres mitigations: 120 (PSC-04 — drift SP, mitigation v7), 40 (PSC-06 — accepte by design)
- RPN > 10 restants: PSC-02 (30), PSC-03 (24), PSC-04 (120), PSC-05 (18), PSC-06 (40), PSC-08 (16)
- PSC-04 (120): seule mitigation reportee a v7 (test integration SP parsing)
- PSC-06 (40): accepte by design (PostToolUse = revele, pas previent)
- H-06 FIX: 6 roles ajoutes (reviewer, compliance, documenter, quality, researcher, consultant)
- PSC-05 FIX: warning reste stderr (stdout causerait faux positif via REASON capture). RPN 36→18
- 46 tests (13 nouveaux pour H-06 + PSC-05). Toutes les mitigations implementables: FAIT + testees

---

## pre-compact-harvest.sh

| # | Mode de defaillance | Cause | Effet | S | O | D | RPN | Mitigation |
|---|---|---|---|---|---|---|---|---|
| PCH-01 | git absent au runtime | Environnement degrade | Hook sort silencieusement, pas de harvest | 3 | 1 | 1 | 3 | FAIT: `command -v git` check, exit 0 gracieux. RPN < 10 |
| PCH-02 | fleet-done.sh absent ou echoue | Deploy incomplet, fleet-done.sh bugge | Harvest collecte mais pas insere dans handoff | 5 | 2 | 2 | 20 | FAIT: `command -v` check + `|| true`. Le snippet est quand meme genere, la copie ready-room fonctionne independamment |
| PCH-03 | /home/projects/ vide (aucun repo git) | Fresh install, projets pas encore clones | Harvest vide (pas d'info git), mais hook termine proprement | 2 | 2 | 1 | 4 | FAIT: boucle for skip si pas de .git. RPN < 10 |
| PCH-04 | Handoff file absent | Instance pas encore initialisee | Copie vers ready-room echoue silencieusement | 3 | 2 | 2 | 12 | FAIT: `[[ -f "$HANDOFF" ]]` check + `|| true`. L'info est dans fleet-done de toute facon |
| PCH-05 | Hook depasse le budget 5s | Trop de projets, git lent (gros repos) | Compaction retardee, risque de timeout CC | 4 | 1 | 5 | 20 | RISQUE RESIDUEL: pas de timeout interne. 5 projets x 4 git calls = ~2s typique. Mitigation v7: `timeout 5s` wrapper |
| PCH-06 | Snippet /tmp/ non nettoyee | Crash entre write et cleanup | Fichier orphelin dans /tmp | 1 | 2 | 1 | 2 | FAIT: `rm -f` en fin de script. /tmp nettoye au reboot. RPN < 10 |
| PCH-07 | Race condition: concurrent compaction | Deux compacts simultanees (theorique) | Deux appels fleet-done.sh, doublon dans handoff | 2 | 1 | 3 | 6 | RPN < 10. Claude Code serialise les compactions |
| PCH-08 | ready-room drvfs mount absent | WSL pas monte, drvfs down | Copie echoue silencieusement, handoff pas visible user | 3 | 2 | 2 | 12 | FAIT: `[[ -d ]]` check + `|| true`. Handoff reste dans /home/handoffs/ |

### Bilan pre-compact-harvest.sh

- 8 modes analyses
- RPN max: 20 (PCH-02, PCH-05)
- Aucun RPN > 10 non mitige sauf PCH-05 (timeout v7)
- PCH-02 (20) et PCH-04 (12), PCH-08 (12): mitigations en place
- Script robuste par design (read-mostly, tolerant aux erreurs)
