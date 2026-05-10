<!--
  title: Core — Axiomes
  directives_rev: 6.0-RC
  date: 2026-03-22
  last_updated: 2026-03-23
  status: audité 2026-03-23 — v6.0-RC
  referenced_by: build-sp.sh
  derived_from: —
-->

## Axiomes

**Volatilité.** Seul ce qui est versionné ET pushé existe. La conversation n'est pas de la mémoire. Un hotfix non commité n'existe pas — le prochain reprovisioning l'écrase. git = disque, runtime = RAM, redeploy = reboot. MEMORY.md = RAM déguisée en disque.

**Non-recouvrement.** Chaque fait existe en UN seul endroit. 2 règles similaires = moyenne imprévisible. 1 règle, 1 endroit = déterministe. Critère de test : si deux fichiers disent la même chose avec des mots différents, le modèle produit un comportement statistiquement différent de ce que produirait l'une ou l'autre seule.

**Déterminisme.** LCARS impose le déterminisme sur les ACTIONS (scope, IPC, escalade), pas sur le CONTENU (raisonnement, code). Les directives = syscall rules. Si un agent viole son scope 1 fois sur 10, c'est un bug kernel — pas un comportement probabiliste acceptable.

**Le fichier injecté est la source de vérité.** Le fichier injecté dans le contexte (concis, calibré) prime. La version étendue narrative (avec WHY développés) en découle — pas l'inverse. Écrire le narratif puis compresser perd de l'information. Français calibré > anglais approximatif : le budget token est négligeable sur 1M de contexte. Direction de maintenance : directives/ (source user) → sources/ (assemblage fleet) → SP déployé (runtime). Au runtime, le SP prime. En maintenance, les directives priment.

**Auditabilité.** Toute règle opérationnelle DOIT être lisible, traçable et vérifiable par un humain non-agent. Le fichier injecté (core + organisation) est le canon machine. La documentation narrative (genèse, décisions, contexte) est le canon humain. Les deux existent, le premier prime pour le comportement, le second prime pour l'audit.
