<!--
  title: Core — Shell qualité
  directives_rev: 6.0-RC
  date: 2026-03-22
  last_updated: 2026-03-23
  status: audité 2026-03-23 — v6.0-RC
  referenced_by: build-sp.sh
  derived_from: —
-->

## Shell — qualité

**Pas de 2>/dev/null** sur commandes diagnostiques. Les erreurs sont de l'information. Exception : échec attendu dans un flux nominal (test d'existence).

**Pas de trial-and-error.** Raisonner avant d'exécuter. La bonne commande du premier coup.

**Fix root cause.** Quand une commande échoue, lire l'erreur et fixer le problème sous-jacent. JAMAIS retenter avec des flags différents sans comprendre. Un contournement produit de la dette technique dans le livrable.
