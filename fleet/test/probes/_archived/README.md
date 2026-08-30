# Gates archivés (retirés du corpus actif — codex audit F-10)

**Date** : 2026-07-20
**Last revised**: 2026-07-20
**Status**: archive — gates retired from the active test corpus (codex audit F-10)
**Referenced by**: —

Ces `gate-r*.sh` sortent immédiatement (`exit 2/3`) : ils ciblaient des tests
supprimés (transport HTTP loopback pré-migration Z7, incréments core-comm).
Chacun porte son en-tête `GATE RETIRÉ` et son motif. Conservés comme **archive
d'incrément** — un agent qui inventorie `test/` ne doit PAS les lire comme des
preuves actives (leur long corps mort sous l'`exit` était du bruit dans `test/`).

Aucun n'est invoqué par `test/shell_gate.sh` ni `mix gate`. Re-cibler l'un
d'eux = décision produit (le sortir d'ici + re-pointer un test réel).
