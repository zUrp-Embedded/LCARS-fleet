# FMEA — Ring 0 Gate (4 scripts)

**Date** : 2026-03-28
**Derniere revision** : 2026-03-28
**Statut** : premiere passe
**Reference par** : v6-rings-and-interfaces.md
**Derive de** : code review Ring 0 gate

---

## Methode

S/O/D echelle 1-10. RPN = S x O x D. Seuil fix : RPN > 10.

| ID | Script | Mode de defaillance | S | O | D | RPN |
|---|---|---|---|---|---|---|
| R0G-01 | hook-config | fleet-env.sh absent → detection LCARS echoue → repo traite comme project | 3 | 1 | 3 | 9 |
| R0G-02 | install-hooks | .git/ absent → symlinks non creees | 2 | 2 | 1 | 4 |
| R0G-03 | install-hooks | symlink existant pointe vers un hook obsolete | 3 | 1 | 4 | 12 |
| R0G-04 | pre-commit | header check trop strict — bloque un commit legitime | 4 | 3 | 2 | 24 |
| R0G-05 | pre-commit | STARDATE calcul faux (date -d non portable) | 2 | 1 | 3 | 6 |
| R0G-06 | pre-commit | pass 1 (date update) modifie un fichier non stage | 5 | 1 | 3 | 15 |
| R0G-07 | install.sh | clone echoue (reseau, auth) — installation incomplete | 6 | 2 | 1 | 12 |
| R0G-08 | install.sh | /local/LCARS existe deja (re-install) → conflit | 3 | 1 | 2 | 6 |

---

## Fixes RPN > 10

| ID | RPN | Action |
|---|---|---|
| R0G-03 | 12 | Acceptable — install-hooks ecrase les symlinks existants. |
| R0G-04 | 24 | **Important.** Le pre-commit peut bloquer si un .md nouveau n'a pas de header. Workaround : --no-verify (mais viole les directives). Documenter les exemptions. |
| R0G-06 | 15 | Acceptable — pass 1 ne modifie que les fichiers stages (git diff --cached). |
| R0G-07 | 12 | Acceptable — git clone error visible. L'user relance. |

---

## Bilan

- 8 modes de defaillance
- 0 critique
- 1 important (R0G-04:24) — pre-commit trop strict
- 7 sous controle
