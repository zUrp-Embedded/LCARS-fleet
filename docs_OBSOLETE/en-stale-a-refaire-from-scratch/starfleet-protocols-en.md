# Starfleet Protocols — LCARS Operational Principles

**Date** : 2026-03-08
**Dernière révision** : 2026-03-08
**Statut** : placeholder initialisé — sections à développer
**Référencé par** : #0_glossaire-systeme.md, #2_system-conventions.md, ONBOARDING.md

Quatre principes opérationnels issus de la convergence métaphore ST → modèle LCARS.
Chaque principe est un alias nommé sur un concept ou protocole existant.
La métaphore n'est pas cosmétique — elle est prédictive et mémorable.

Référence : `Captain_log.md` Phase 11 — convergence ST/LCARS.

---

## IDIC — Infinite Diversity in Infinite Combinations

*Philosophie vulcaine : la diversité est la source de valeur, pas une tolérance passive.*

**Mapping LCARS** : tout composant fleet doit fonctionner sans hypothèse mono-environnement.

**IDIC targets** : ARM64, x86-64, Ubuntu, Debian, WSL2, Linux natif.

**IDIC-compliant** : qualifie un composant (script, skill, hook, binaire) qui respecte cette contrainte — pas d'hypothèse hardcodée sur l'arch, l'OS, le username, les chemins absolus non-configurables.

**Critère de revue** : "est-ce IDIC-compliant ?" est une question valide en revue de code ou de script. Si la réponse est non, le composant a une dette IDIC à documenter.

**Mode de défaillance** : script qui hardcode `/home/lordzurp/`, binaire compilé x86-only sans flag, hook qui suppose `bash` en `/bin/bash` sans shebang robuste.

---

## Holodeck Containment

*Le Holodeck simule un environnement complet. Les règles du réel ne s'y appliquent pas — jusqu'à la containment failure.*

**Mapping LCARS** : l'instance qualifier est un Holodeck. Elle peut tout lire, mais son périmètre d'écriture est strictement borné.

**Périmètre write qualifier (Holodeck)** :
- `test-queue.md` — file de tests entrants
- `to-engineer.md` — escalades uniquement
- son propre handoff (`qualifier-handoff.md`)

**Containment failure** : écriture qualifier hors périmètre — handoffs prod, canaux dev, code projet. Symptômes : merge conflict inattendu, fichier prod modifié sans commit dev, état incohérent dans un handoff non-qualifier.

**Recovery** : `git diff` sur les fichiers suspects, `git log --author` pour identifier la source, revert si nécessaire. La containment failure est un incident à journaliser dans `bug-journal.md`.

**Note filesystem** : l'instance qualifier n'a pas accès à `/home/wsl-root/` (drvfs non monté). Tout fichier destiné à qualifier doit être copié dans `/home/commons/` au préalable — c'est une containment structurelle, pas un bug.

---

## First Contact Protocol

*Starfleet ne contacte pas une nouvelle civilisation à l'improviste. Évaluation préalable, protocole strict, handshake bidirectionnel.*

**Mapping LCARS** : onboarding d'un nouveau projet dans la fleet. Le protocole est bidirectionnel — le projet doit être prêt à recevoir LCARS, et LCARS doit être prêt à opérer le projet.

### Checklist côté projet

- [ ] `docs_and_plans/` créé avec structure `guides_FR/`, `guides_EN/`, `work/todo/doing/done/`
- [ ] `.gitignore` couvre `.env`, secrets, artefacts build
- [ ] `.env.example` documenté si secrets nécessaires
- [ ] `CLAUDE.md` projet créé (ou LCARS global suffisant)
- [ ] `docs_and_plans/guides_FR/bug-journal.md` initialisé

### Checklist côté fleet

- [ ] Entrée dans `fleet.yaml` (user, distro, projet, arch)
- [ ] Session tmux nommée (convention `<projet>-<rôle>`)
- [ ] Handoff initialisé (`<instance>-handoff.md` dans `/home/commons/`)
- [ ] Instance provisionnée (`deploy.sh` exécuté)
- [ ] CLAUDE.md fleet déployé dans le home de l'instance

**Sans First Contact complet** : comportement non-défini. L'agent opère sans contexte projet, sans handoffs, sans journal de bugs. Equivalent d'un équipage qui débarque sur une planète sans briefing.

---

## Temporal Prime Directive

*Interdiction absolue d'interférer avec la timeline. Même avec de bonnes intentions.*

**Mapping LCARS** : le commit graph est la timeline. Chaque commit est un événement causal. Les réécrire après publication crée des paradoxes temporels — états divergents entre agents qui ont déjà fetché.

**Violations TPD** :
- `git push --force` sur une branche partagée
- `git commit --amend` sur un commit déjà poussé
- `git rebase` sur une branche dont d'autres agents ont des copies
- `git reset --hard` sur un état partagé sans coordination explicite

**Paradoxe temporel** : merge conflict sur des commits réécrits que d'autres agents (ou builders) ont déjà fetchés. Récupération coûteuse, parfois impossible proprement.

**Exception légitime** : `--force-with-lease` sur une branche feature personnelle non-partagée, avec mention explicite dans le handoff. Pas sur `main`.

**Mnémotechnique** : "La timeline est sacrée." Avant tout `--force`, demander : est-ce que quelqu'un d'autre a déjà vu ce commit ?
