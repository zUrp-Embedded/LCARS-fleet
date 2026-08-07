# FMEA — Ring 4 Support (6 scripts)

**Date** : 2026-03-28
**Derniere revision** : 2026-03-28
**Statut** : premiere passe
**Reference par** : v6-rings-and-interfaces.md
**Derive de** : code review manuelle Ring 4

---

## Methode

S/O/D echelle 1-10. RPN = S x O x D. Seuil fix : RPN > 10.

---

## Bloc 1 — Lanceurs (fleet-sf, fleet-arch)

| ID | Script | Mode de defaillance | S | O | D | RPN | Mitigation |
|---|---|---|---|---|---|---|---|
| R4S-01 | fleet-sf | yq absent — socket path par defaut utilisé | 2 | 1 | 2 | 4 | tmux default socket (no custom -S). N/A. |
| R4S-02 | fleet-sf | tmux socket permissions insuffisantes | 4 | 2 | 3 | 24 | Le socket est créé par fleet-launch.sh avec les bonnes permissions. Si absent, tmux new-session le crée. |
| R4S-03 | fleet-sf | Pane starfleet-fleet kill échoue (C-c ignoré) | 2 | 1 | 5 | 10 | sleep 0.5 + exit Enter. Si le process ignore les deux, le pane reste. Non-critique. |
| R4S-04 | fleet-arch | .deploy_ok absent — utilisateur bloqué | 3 | 2 | 1 | 6 | Message clair. By design — force l'onboarding. |
| R4S-05 | fleet-sf/arch | --dangerously-skip-permissions dans la commande claude | 7 | 1 | 8 | 56 | Nécessaire pour les sessions autonomes. Le risque est atténué par le scope des directives dans le SP. Si un agent déraille, aucun garde-fou Claude Code. |

## Bloc 2 — Lifecycle (fleet-restart, fleet-shutdown-clean, herald, lcars-test)

| ID | Script | Mode de defaillance | S | O | D | RPN | Mitigation |
|---|---|---|---|---|---|---|---|
| R4S-10 | fleet-restart | light_off échoue mais light_on lance quand même | 3 | 1 | 3 | 9 | light_off || exit 0 stoppe si light_off échoue. Le || exit 0 est correct. |
| R4S-11 | fleet-restart | sleep 2 insuffisant — light_on démarre avant que l'ancien process soit mort | 4 | 2 | 5 | 40 | Le sleep est un heuristique. Si le process met >2s à mourir, conflit. Ajouter un check que le pane est vide avant light_on. |
| R4S-12 | shutdown-clean | awk rewrite corrompt le handoff (crash mid-write) | 7 | 1 | 5 | 35 | .tmp + mv est atomique sur ext4. Risque sur drvfs (meme pattern que R2S-04). |
| R4S-13 | shutdown-clean | ACTIONS contient du markdown complexe mal parsé par awk | 3 | 2 | 4 | 24 | awk cherche "^## ACTIONS" en début de ligne. Si ACTIONS contient des sous-sections ##, le parsing s'arrete au premier ##. |
| R4S-14 | herald | Pas de session tmux "fleet" — notification silencieusement ignorée | 2 | 3 | 3 | 18 | By design — herald est non-bloquant. Si la fleet est offline, pas de notification. |
| R4S-15 | herald | tmux display-message avec caractères spéciaux — injection tmux | 5 | 1 | 6 | 30 | WAITING et NOTIFY viennent de fleet-state.sh (controlé). Si un agent injecte du contenu malveillant, le display-message peut exécuter des commandes tmux. |
| R4S-16 | lcars-test | Session "lcars" déjà active — attach au lieu de créer | 1 | 3 | 1 | 3 | Comportement attendu. |
| R4S-17 | lcars-test | ~/.tmux.lcars.conf absent — tmux utilise config par défaut | 2 | 2 | 3 | 12 | Layout fonctionne sans config custom. Apparence dégradée seulement. |

---

## Fixes RPN > 10

| ID | RPN | Action |
|---|---|---|
| R4S-02 | 24 | Acceptable — socket géré par fleet-launch. |
| R4S-05 | 56 | **Important.** Le --dangerously-skip-permissions est un choix délibéré pour les sessions autonomes. Le vrai garde-fou est le SP + hooks. Documenter le risque. |
| R4S-11 | 40 | **Important.** Ajouter un check "pane vide" (tmux capture-pane + grep) avant light_on. Ou augmenter le sleep à 5s. |
| R4S-12 | 35 | **Important.** Meme pattern drvfs que R2S-04. Documenter la limitation. |
| R4S-13 | 24 | Acceptable — le contenu ACTIONS est normalement des listes [ ] simples. |
| R4S-14 | 18 | By design. Documenter. |
| R4S-15 | 30 | Acceptable en pratique — le contenu vient de fleet-state (contrôlé). Ajouter un sanitize sur WAITING/NOTIFY si exposé à du contenu user. |
| R4S-17 | 12 | Acceptable — dégradation visuelle seulement. |

---

## Bilan Ring 4 Support

- 13 modes de defaillance analyses (2 blocs)
- 0 critique (aucun RPN > 100)
- 3 importants (R4S-05:56, R4S-11:40, R4S-12:35) — mitigations proposées
- 4 a surveiller (RPN 12-30) — acceptables
- 10 sous controle (RPN < 10)
