# Créer ou adopter un projet

**Date** : 2026-03-21
**Dernière révision** : 2026-03-30
**Statut** : guide opératoire
**Référencé par** : #00_index.md, #24_quick-start-projet.md

> Cette doc couvre l'entrée d'un projet dans LCARS : création neuve, adoption d'un repo existant, et premier rattachement au cadre fleet.

Détail runtime : `fleet-init-project.sh --help`.

---

## Deux portes d'entrée

| Cas | Point d'entrée |
|---|---|
| projet neuf | `/new-project` |
| projet existant | `/adopt-project` |

Dans les deux cas, l'objectif est le même :
- un projet exploitable par architect
- une structure `work/` cohérente
- un cadre de travail relisible

---

## Projet neuf

Déclenchement :

```text
nouveau projet : <description courte>
```

Architect collecte le minimum utile :
- nom / slug
- titre
- type de projet
- stack principale
- livrables attendus
- licence
- présence ou non d'un repo distant

Résultat attendu :
- repo initialisé
- README et fichiers de base
- structure projet cohérente
- `work/` prêt

---

## Projet existant

Déclenchement :

```text
adopte ce projet : <url ou chemin local>
```

Effet attendu :
- scan du dépôt existant
- ajout de la structure manquante
- rattachement au cadre LCARS sans réécrire arbitrairement le projet

But :
- intégrer un projet réel à la boîte
- pas le “recréer” depuis zéro

---

## Forme attendue du projet

```text
/home/projects/<slug>/
├── README.md
├── src/ ou équivalent
├── docs/
└── work/
```

Le détail exact dépend du type de projet. Le point important est la présence d'un espace de travail LCARS clair.

---

## Rattachement au domaine L2

Si le projet exige une spécialisation métier, elle ne passe pas par le profil fleet mais par le L2.

Exemple :
- firmware
- hardware
- web
- data

Le binding se fait côté configuration fleet puis redeploy.

---

## Lire ensuite

- [#24_quick-start-projet.md](#24)
- [#26_user-guide.md](#26)
- [#02_knowledge-hierarchy.md](#02)
