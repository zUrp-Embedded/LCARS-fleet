# Starfleet Protocols — Principes opérationnels LCARS

**Date** : 2026-03-21
**Dernière révision** : 2026-03-21
**Statut** : référence active
**Référencé par** : fleet/system-prompt/sources/core/#1_general-orders.md
**Dérivé de** : —

Quatre principes opérationnels issus de la convergence Star Trek → modèle LCARS. Chaque principe est un alias nommé sur un concept système. La métaphore est prédictive et mémorable, pas cosmétique.

Principes canoniques définis dans `regles.md` (§ Starfleet Principles). Ce document les développe avec exemples, modes de défaillance, et critères de vérification.

---

## IDIC — Infinite Diversity in Infinite Combinations

**Principe** : tout composant fleet fonctionne sans hypothèse mono-environnement.

**Cibles** : ARM64, x86-64, Ubuntu, Debian, WSL2, Linux natif.

**IDIC-compliant** qualifie un composant (script, skill, hook, binaire) qui ne fait aucune hypothèse hardcodée sur l'arch, l'OS, le username, ou les chemins absolus non-configurables.

**Critère de revue** : "est-ce IDIC-compliant ?" est une question valide en revue de code.

**Modes de défaillance** :
1. Script qui hardcode un username au lieu de `$USER` ou `fleet.yaml`
2. Binaire compilé x86-only sans flag arch
3. Hook qui suppose `bash` sans shebang robuste
4. Path absolu non résolu depuis `fleet-env.sh`

---

## Holodeck Containment

**Principe** : chaque instance opère dans un périmètre write borné et explicite. Écriture hors périmètre = incident.

Défini dans `regles.md` (§ Holodeck Containment). Le corollaire récursif : la fleet a exactement deux sorties (StarFleet côté OS, Architect côté User).

**Exemple — qualifier** :
- Write autorisé : son handoff, messages spool sortants (`fleet-send.sh`), rapports dans son home
- Write interdit : handoffs d'autres agents, code projet, canaux dev

**Containment failure** : écriture hors périmètre. Symptômes : merge conflict inattendu, fichier modifié sans commit identifiable, état incohérent dans un handoff étranger.

**Recovery** : `git diff` sur les suspects, `git log --author` pour identifier la source, revert si nécessaire. Journaliser dans `bug-journal.md`.

---

## Temporal Prime Directive

**Principe** : le commit graph est immuable après publication.

Défini dans `regles.md` (§ Temporal Prime Directive). Violations :

1. `git push --force` sur branche partagée
2. `git commit --amend` sur commit déjà poussé
3. `git rebase` sur branche fetchée par d'autres agents
4. `git reset --hard` sur état partagé sans coordination

**Paradoxe temporel** : merge conflict sur commits réécrits que d'autres agents ont déjà fetchés. Récupération coûteuse, parfois impossible proprement.

**Exception** : `--force-with-lease` sur branche feature personnelle non-partagée, avec mention handoff.

---

## Shakedown Protocol (Déverminage)

**Principe** : tout livrable passe par un cycle de déverminage dans le containment avant sortie.

Défini dans `regles.md` (§ Shakedown Protocol). Le containment est l'enceinte de déverminage — environnement contrôlé, jetable, recovery en minutes.

**Le nombre d'itérations est le chemin nominal, pas un indicateur d'échec.** Un agent qui produit un résultat correct en 10 passes a mieux travaillé qu'un agent qui livre en 1 passe avec un bug latent.

**Modes de défaillance** :
1. Agent conservateur qui temporise par peur du blast radius (biais training)
2. Agent qui livre vite sans vérification complète
3. Les deux violent ce principe — le premier par excès de prudence, le second par défaut de rigueur

**Gate de sortie** : qualifier, fleet-doctor, test hardware. Seul ce qui survit au déverminage est déployé.
