# Troubleshooting — diagnostic et reprise

**Date** : 2026-03-21
**Dernière révision** : 2026-03-30
**Statut** : guide opératoire
**Référencé par** : #00_index.md, ONBOARDING.md

> `fleet-doctor.sh` d'abord. Ensuite seulement, arbre de décision adapté au symptôme.

Détail commandes : `fleet-doctor.sh --help`, `fleet-fetch.sh --help`, `wake-instance.sh --help`.

---

## Premier réflexe

```bash
fleet-doctor.sh
fleet-doctor.sh --section 3
```

But :
- distinguer incident runtime, incident agent, et simple dérive de session
- éviter les fixes à l'aveugle

---

## La fleet ne démarre pas

```text
~/start échoue
  ├── "session already exists"
  │   └── ~/stop puis ~/start
  ├── "command not found"
  │   └── vérifier les alias shell et light_on.sh
  └── panes manquantes
      ├── fleet-doctor.sh → users / groups / tmux
      ├── WSL lent → délai de boot trop court
      └── dépendance système absente → reprovision / redeploy
```

---

## Un agent ne répond pas

```text
agent muet
  ├── tmux : la fenêtre existe ?
  │   ├── non → runtime incomplet, redeploy
  │   └── oui
  ├── handoff : dernier état connu cohérent ?
  ├── fleet-fetch.sh <role>
  │   ├── pending → wake-instance.sh <role> "check inbox"
  │   └── vide → message jamais envoyé ou déjà consommé
  └── claude --resume / relance propre si la session est morte
```

Signaux utiles :
- handoff stale
- blocker explicite
- session Claude crashée
- queue inbox non vide depuis trop longtemps

---

## Message perdu ou bloqué

```text
message absent du comportement attendu
  ├── spool inbox/<dest>/ : présent ?
  │   ├── non → envoi raté
  │   └── oui
  ├── .processing/ ou .consumed/ ?
  ├── permissions du spool correctes ?
  └── réveil manuel du destinataire
```

Points à vérifier :
- `/var/spool/fleet/inbox/<role>/`
- ownership et groupe `fleet`
- message encore pending via `fleet-fetch.sh <role>`

---

## Le déploiement n'a pas pris effet

```text
modification visible dans le repo mais pas dans le runtime
  ├── deploy lancé ?
  ├── fleet-doctor.sh : FAIL git / directives / users ?
  ├── fleet-check-coherence.sh : drift CLAUDE.md ?
  └── fleet-update.sh --force
```

Règle :
- en cas de doute, redeploy propre
- ne pas patcher l'instance vivante pour “voir si ça repart”

---

## Les locks bloquent l'avancement

```text
opération bloquée
  ├── build ou transition réellement en cours → attendre
  └── lock zombie → fleet-lock-cleanup.sh
```

Éviter :
- suppression manuelle brutale de locks sans diagnostic préalable
- relance multiple de la même commande “pour voir”

---

## Dérive comportementale

Cas typiques :
- ton ou registre qui dérive
- reformulation du déjà-dit
- confusion de scope
- agent qui semble avoir “lu” une règle mais agit à côté

À faire :
- reset de session si la dérive est conversationnelle
- `fleet-check-coherence.sh` si tu soupçonnes un drift de déploiement
- redeploy si le runtime ne reflète plus clairement la source

Important :
- une règle peut être comprise puis contournée
- si le problème exige une garantie dure, la réponse est mécanique, pas rhétorique

---

## Outils utiles

| Outil | Usage |
|---|---|
| `fleet-doctor.sh` | diagnostic général |
| `fleet-check-coherence.sh` | drift source vs déployé |
| `fleet-maintenance.sh` | health checks périodiques |
| `fleet-lock-cleanup.sh` | nettoyage des locks zombies |
| `watch-handoff.sh <role>` | suivi handoff en direct |
| `fleet-fetch.sh <role>` | messages pending |
