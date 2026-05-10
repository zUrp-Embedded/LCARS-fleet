# FMEA — Ring 1 Support (3 scripts + 1 Python)

**Date** : 2026-03-28
**Derniere revision** : 2026-03-28
**Statut** : premiere passe
**Reference par** : v6-rings-and-interfaces.md
**Derive de** : code review Ring 1 support

---

## Methode

S/O/D echelle 1-10. RPN = S x O x D. Seuil fix : RPN > 10.

| ID | Script | Mode de defaillance | S | O | D | RPN |
|---|---|---|---|---|---|---|
| R1S-01 | fleet-wake-notify | tmux socket absent → sentinel pas injecte, .wake ecrit | 2 | 3 | 2 | 12 |
| R1S-02 | fleet-wake-notify | agent non-wakeable mal detecte (yq query echoue) | 3 | 1 | 4 | 12 |
| R1S-03 | fleet-wake-notify | .wake file jamais consomme (pas de reader) | 3 | 2 | 6 | 36 |
| R1S-04 | fleet-wake-notify | [FLEET-INBOX] sentinel injecte dans le mauvais pane (fleet_find_pane bug) | 6 | 1 | 4 | 24 |
| R1S-05 | fleet-alert | PID recyclage — "already running" faux positif | 3 | 1 | 4 | 12 |
| R1S-06 | fleet-alert | sudo tmux echoue (permissions) → blink loop crash silencieux | 4 | 2 | 5 | 40 |
| R1S-07 | fleet-alert | inbox check `ls *.md` globbing echoue si inbox vide (nullglob) | 2 | 3 | 3 | 18 |
| R1S-08 | fleet-hub.py | Port deja utilise → serveur ne demarre pas | 3 | 2 | 1 | 6 |
| R1S-09 | fleet-hub.py | Handoff file mal forme → JSON response invalide | 4 | 2 | 4 | 32 |
| R1S-10 | fleet-hub.py | Pas de timeout sur les requetes → thread bloque | 3 | 1 | 5 | 15 |

---

## Fixes RPN > 10

| ID | RPN | Action |
|---|---|---|
| R1S-01 | 12 | Acceptable — .wake fallback est le design prevu. |
| R1S-02 | 12 | Acceptable — fallback wakeable=true si yq echoue. |
| R1S-03 | 36 | **Important.** Les .wake files ne sont lus par personne actuellement. Backlog v7 : consumer dans light_on.sh au boot. |
| R1S-04 | 24 | Acceptable — fleet_find_pane utilise @fleet-role user option, robuste. |
| R1S-05 | 12 | Acceptable — edge case rare. |
| R1S-06 | 40 | **Important.** sudo tmux peut echouer si le tmux socket owner ne match pas. Ajouter un test pre-blink. |
| R1S-07 | 18 | Acceptable — ls *.md avec &>/dev/null. Si vide, la boucle s'arrete (comportement voulu). |
| R1S-09 | 32 | **Important.** Ajouter try/except autour du parsing handoff dans fleet-hub.py. |
| R1S-10 | 15 | Acceptable — BaseHTTPServer est single-threaded par defaut. |

---

## Bilan

- 10 modes de defaillance
- 0 critique
- 3 importants (R1S-03:36, R1S-06:40, R1S-09:32)
- 7 sous controle
