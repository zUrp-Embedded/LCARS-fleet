# FMEA — Ring 3 Support (12 scripts)

**Date** : 2026-03-28
**Derniere revision** : 2026-03-28
**Statut** : premiere passe
**Reference par** : v6-rings-and-interfaces.md
**Derive de** : bash-pro audit, tests BATS Ring 3

---

## Methode

S/O/D echelle 1-10. RPN = S x O x D. Seuil fix : RPN > 10.

---

## Bloc 1 — Health (fleet-doctor, fleet-check-coherence, fleet-context-check, drift-check)

| ID | Script | Mode de defaillance | S | O | D | RPN | Mitigation |
|---|---|---|---|---|---|---|---|
| R3S-01 | fleet-doctor | yq/jq absent — sections entières sautées | 4 | 1 | 2 | 8 | Doctor lui-même vérifie les prereqs en section 0. Acceptable. |
| R3S-02 | fleet-doctor | Faux PASS sur permission (stat -c non portable sur macOS) | 3 | 2 | 5 | 30 | stat -c est Linux-only. macOS utilise stat -f. Ajouter portabilité si target macOS. |
| R3S-03 | fleet-doctor | SC2015 pattern (A && B \|\| C) — _pass échoue, _fail exécuté à tort | 2 | 1 | 3 | 6 | _pass/_fail sont des echo — ne peuvent pas échouer. Faux positif shellcheck. |
| R3S-04 | check-coherence | md5sum non disponible (macOS = md5) | 3 | 1 | 4 | 12 | Linux-only pour l'instant. Portabilité à ajouter si besoin. |
| R3S-05 | check-coherence | CLAUDE.md source modifié mais pas encore pushé — faux positif drift | 2 | 3 | 3 | 18 | Comportement attendu : drift = diff entre source et déployé. L'agent le signale, engineer décide. |
| R3S-06 | check-coherence | fleet-send.sh absent — drift non signalé | 5 | 1 | 3 | 15 | Script affiche un WARN sur stderr. L'output console reste visible. |
| R3S-07 | context-check | JSONL path introuvable (session ID invalide) | 1 | 3 | 1 | 3 | Silent exit 0. Non-bloquant by design. |
| R3S-08 | context-check | Mauvais calcul pourcentage (cache tokens non comptés) | 4 | 2 | 6 | 48 | Le calcul inclut cache_creation + cache_read. Si Anthropic change le format usage, le script sous-estime. |
| R3S-09 | drift-check | Compteur commit stale (fleet-state jamais mis à jour) | 3 | 2 | 5 | 30 | Le compteur est mis à jour par fleet-update.sh. Si fleet-update n'est jamais exécuté, le compteur reste à 0 → alerte perpétuelle. |

## Bloc 2 — Orchestration (fleet-maintenance, fleet-fetch, fleet-init-project)

| ID | Script | Mode de defaillance | S | O | D | RPN | Mitigation |
|---|---|---|---|---|---|---|---|
| R3S-10 | fleet-maintenance | Handoff date non parseable (format inattendu) | 2 | 2 | 3 | 12 | date -d échoue silencieusement → skip. Non-bloquant. |
| R3S-11 | fleet-maintenance | tmux socket inaccessible (fleet offline) | 2 | 3 | 2 | 12 | Loggé proprement. Non-bloquant. |
| R3S-12 | fleet-maintenance | Sentinel hourly T3 → rate miss si WSL reboot intra-hour | 1 | 2 | 4 | 8 | Acceptable — T3 est un check de confort. |
| R3S-13 | fleet-fetch | Lockfile orphelin après crash → fetch bloqué | 5 | 2 | 5 | 50 | Pas de timeout sur le lockfile. Un crash laisse le lock permanent. Ajouter un check d'âge max (1h). |
| R3S-14 | fleet-fetch | git pull --ff-only échoue (divergence) | 6 | 1 | 2 | 12 | Exit 1 + log. Intervention manuelle requise. Détecté. |
| R3S-15 | fleet-fetch | deploy.sh échoue après pull → état incohérent (code à jour, deploy cassé) | 7 | 1 | 4 | 28 | Le pull a réussi mais le deploy non. Loggé comme WARN mais l'état est partiellement mis à jour. |
| R3S-16 | fleet-init-project | L2 domain vide — cold start sans contexte | 2 | 4 | 1 | 8 | Affiche "cold start" explicitement. Comportement nominal. |
| R3S-17 | fleet-init-project | Python filter bug — entrée utile supprimée | 5 | 1 | 5 | 25 | Filtre basé sur date+hits. Si le frontmatter est mal formaté, l'entrée est traitée comme "fresh" (conservée). |

## Bloc 3 — Support (fleet-bug, fleet-lock-cleanup, fleet-l2-hits, starfleet-notes-check, fleet-inbox-watch-daemon)

| ID | Script | Mode de defaillance | S | O | D | RPN | Mitigation |
|---|---|---|---|---|---|---|---|
| R3S-20 | fleet-bug | fleet-send.sh absent → bug non reporté | 4 | 1 | 1 | 4 | Exit 1 avec message clair. Testé. |
| R3S-21 | fleet-lock-cleanup | Lock valide supprimé (timestamp parsing error) | 5 | 1 | 3 | 15 | Le script vérifie que le timestamp est numérique et > 0. Si le format owner change, risque. |
| R3S-22 | fleet-l2-hits | Python atomic write échoue (disque plein, permissions) | 4 | 1 | 3 | 12 | tempfile + os.replace + cleanup dans except. Standard Python. |
| R3S-23 | fleet-l2-hits | Sync L2-active → canonical écrase une version plus récente | 4 | 1 | 5 | 20 | cp sans vérification de date. Si le canonical a été modifié entre init-project et hits increment, la modif est perdue. |
| R3S-24 | notes-check | Regex section removal supprime du contenu adjacent (Python regex greedy) | 5 | 1 | 5 | 25 | Le regex utilise .*? (non-greedy) mais le pattern dépend de la structure exacte des commentaires HTML <!-- id: -->. |
| R3S-25 | inbox-watch-daemon | inotifywait absent → exit 1 au démarrage | 2 | 2 | 1 | 4 | Message clair. Fallback = systemd path unit. |
| R3S-26 | inbox-watch-daemon | PID file orphelin → daemon jamais relancé | 3 | 2 | 4 | 24 | Le script vérifie kill -0 avant de déclarer "already running". Si le PID est recyclé, faux positif. |

---

## Fixes RPN > 10

| ID | RPN | Action |
|---|---|---|
| R3S-02 | 30 | Acceptable — Linux-only pour l'instant. Documenter limitation macOS. |
| R3S-05 | 18 | Comportement attendu. Documenter dans man page. |
| R3S-06 | 15 | Acceptable — WARN visible en console. |
| R3S-08 | 48 | **Important.** Si Anthropic change le format usage JSONL, le % sera faux. Ajouter un fallback: si aucun champ usage trouvé, émettre un warning au lieu de silence. |
| R3S-09 | 30 | Acceptable — le compteur se met à jour à chaque fleet-update. |
| R3S-13 | 50 | **Important.** Ajouter un check d'âge max sur le lockfile (>1h → suppression automatique). |
| R3S-15 | 28 | **Important.** Ajouter un rollback git si deploy échoue (git checkout HEAD^), ou au minimum un message fleet-send à starfleet. |
| R3S-17 | 25 | Acceptable — mode "fresh" par défaut protège contre la perte. |
| R3S-21 | 15 | Acceptable — format stable. |
| R3S-22 | 12 | Acceptable — pattern Python standard. |
| R3S-23 | 20 | Acceptable en pratique (L2 canonical rarement modifié entre sessions). Documenter. |
| R3S-24 | 25 | Acceptable — structure HTML comments est stable. Ajouter un test de non-regression. |
| R3S-26 | 24 | Acceptable — le check kill -0 + PID recyclage est un edge case rare. |

---

## Bilan Ring 3 Support

- 24 modes de defaillance analyses (3 blocs)
- 0 critique (aucun RPN > 100)
- 3 importants (R3S-08:48, R3S-13:50, R3S-15:28) — mitigations proposées
- 8 a surveiller (RPN 12-30) — acceptables
- 16 sous controle (RPN < 10)
