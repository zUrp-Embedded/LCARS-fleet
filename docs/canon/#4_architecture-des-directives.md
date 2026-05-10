# Architecture des directives — LCARS actuel

**Date** : 2026-03-30
**Dernière révision** : 2026-03-30
**Statut** : référence extensive
**Référencé par** : canon/README.md
**Dérivé de** : design-history/#6_claude-md-architecture.md

> LCARS ne considère pas les directives comme un décor conversationnel. Elles sont une couche active du système, donc elles doivent rester compactes, ciblées, et placées là où elles ont le plus de chances d'être effectivement suivies.

---

## 1. Une directive active est un budget contraint

Chaque token de directive consomme du contexte et concurrence :
- l'historique
- le code lu
- le raisonnement
- les outils

Pourquoi :
- une directive longue mais mal située peut être vraie sur le papier et faible dans l'exécution

---

## 2. Le global doit rester court

Le tronc commun des directives doit rester :
- stable
- compact
- toujours pertinent

Le rôle-spécifique doit vivre dans des couches séparées.

Pourquoi :
- LCARS préfère la précision par rôle à l'empilement d'un gros texte unique

---

## 3. Une règle importante doit être bien placée

Les règles critiques doivent être :
- précoces
- explicites
- peu redondantes

Pourquoi :
- la directive n'est pas seulement une question de contenu
- c'est aussi une question de placement dans un contexte fini

---

## 4. La redondance a un coût

Répéter une même règle dans plusieurs couches produit :
- gaspillage de contexte
- risque de divergence
- difficulté de maintenance

Pourquoi :
- si une règle importante change, LCARS doit pouvoir l'actualiser sans chasse au duplicata

---

## 5. La lecture progressive est une propriété utile

Toutes les règles n'ont pas besoin d'être chargées en permanence.

Certaines informations gagnent à rester :
- spécialisées
- appelées à la demande
- proches du rôle ou du domaine concerné

Pourquoi :
- la bonne architecture documentaire réduit le bruit sans cacher la vérité active

---

## 6. La doc n'est pas une extension cachée des directives

Une directive active doit vivre dans le runtime ou les sources de directives.

Une doc de cadrage peut expliquer :
- pourquoi cette architecture existe
- où vit la vérité active
- comment intervenir sans créer de couche normative clandestine

Pourquoi :
- sinon on mélange règles effectives et commentaire, et plus personne ne sait ce qui gouverne réellement

---

## 7. Ce qui reste valide au-delà d'un modèle

Même si la forme concrète du fichier déployé change, les principes restent :
- contexte fini
- placement important
- rôle-spécifique préférable au texte uniforme
- vérité active distincte de la doc explicative

---

## Lire ensuite

- [README.md](README.md)
- [../#18_runtime-catalog.md](../#18_runtime-catalog.md)
- [../#20_working-on-lcars.md](../#20_working-on-lcars.md)
- [../design-history/#6_claude-md-architecture.md](../design-history/#6_claude-md-architecture.md)
