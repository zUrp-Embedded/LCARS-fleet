---
name: state_of_the_fleet
description: >
  Relevé d'état et diagnostic de la fleet, du système et de la forge, depuis un pod.
  Deux entrées : `report` (ce qui est vrai maintenant) et `diag` (ce qui est entreprenable).
  Rapporte, ne répare jamais.
allowed-tools:
  - Bash(sotf.sh:*)
  - Bash(~/.claude/skills/state_of_the_fleet/sotf.sh:*)
  - Read
  - Write
when_to_use: >
  Use when the user asks for the state of the fleet, a health report, or why something
  is not working. Also before undertaking a fleet gesture whose dependencies may be down.
  Examples: 'state of the fleet', 'ça marche pas, qu'est-ce qui est cassé ?',
  'est-ce que je peux créer un projet ?', '/state_of_the_fleet report'.
argument-hint: "report | diag [capacité]"
---

# Skill : state_of_the_fleet

**Date** : 2026-07-31
**Dernière révision** : 2026-07-31
**Statut** : actif — starfleet (tous les pods construits pareil peuvent le porter)
**Référencé par** : `BACKLOG.md` (BL-6-22), `beyond_#6/chantier-state-of-the-fleet-2026-07-31/`

---

## La règle qui prime sur tout le reste

**On rapporte. On ne répare pas.** Ni le système, ni la conformité des sondes à lui. Un écart
constaté est un **produit** du relevé, pas une dette à solder dans la foulée. Le chemin pour réparer
est un autre chantier, et il appartient à l'humain — un outil qui répare pendant qu'il mesure ne
mesure plus rien.

Corollaire pour l'agent : ne modifie **aucun** fichier du runtime, du deploy ou d'un cap-profile
parce qu'une sonde l'a signalé. Le geste attendu est de **transmettre**, pas d'agir.

---

## Les deux entrées

Le script vit **à côté de ce fichier**. Dans un pod, le skill est monté en
`~/.claude/skills/state_of_the_fleet/` ; hors pod, c'est le répertoire du skill dans le dépôt.
L'invoquer par son chemin, jamais en supposant un `cwd` :

    S=~/.claude/skills/state_of_the_fleet          # hors pod : le repertoire de ce SKILL.md

    $S/sotf.sh report                      # tout, au terminal
    $S/sotf.sh report --out rapport.md     # tout, en markdown archivable
    $S/sotf.sh diag                        # toutes les capacités
    $S/sotf.sh diag project_create         # une seule chaîne, court-circuitée au premier maillon mort
    $S/sotf.sh report --raw                # le JSONL brut : c'est LUI la source de vérité

Le toolkit est **en lecture seule par construction** : la seule écriture qu'il fait est le fichier de
`--out`. Tout `git` passe par un wrapper `--no-optional-locks` — une sonde qui prendrait `index.lock`
serait un diagnostic *causant* l'incident qu'il rapporte.

**`report`** répond à *« qu'est-ce qui est vrai en ce moment ? »* — six plans de sondes, un tableau,
un horodatage. Se lit, s'archive, se compare à celui d'hier.

**`diag`** répond à *« qu'est-ce que je peux entreprendre ? »* — des verdicts de **capacité**, pour
ne pas dépenser un spawn sur un geste dont un maillon est mort, ni s'acharner à poller un service
qui ne répondra jamais.

Codes de sortie : `0` conforme · `1` drift · `2` erreur-de-sonde. **L'erreur l'emporte sur le
drift** : un run qui n'a pas pu mesurer est pire qu'un run qui a trouvé, parce que son silence a
l'air sain.

Le vocabulaire des verdicts et la façon de lire une ligne vivent dans **`FORMAT.md`**, à côté.
Le lire avant de commenter un rapport — un `inactive` pris pour une panne fabrique une fausse alarme,
un `unreachable` pris pour un `degraded` fabrique un mensonge.

---

## LA COUTURE — ce que les sondes ne peuvent pas voir, et que toi seul sais

Les sondes mesurent des **fichiers, des sockets et des réponses HTTP**. Elles ne voient pas ta
session. Quatre choses te sont accessibles et leur sont fermées :

| Question | Ce que la sonde voit | Ce que tu es seul à savoir |
|---|---|---|
| Quels outils MCP sont **chargés** | la déclaration du cap-profile, la trace du launcher, la socket | la liste réellement montée dans ta session |
| Les skills déclarés sont-ils **utilisables** | leur présence sur disque | s'ils se sont chargés et s'ils répondent |
| Le contrat de protocole injecté est-il **suivi** | ses marqueurs dans le fichier | lequel tu appliques réellement |
| Le modèle et l'effort déclarés | l'env posé par le launcher | ce que tu es effectivement en train de tourner |

Quand tu rends un rapport, ajoute ces éléments dans une section séparée intitulée
**« déclaré par l'agent (témoignage, non mesuré) »**.

⚠ **Ne les fusionne jamais avec les lignes de sonde.** Une sonde est reproductible ; ton
introspection ne l'est pas. Les mélanger donnerait au rapport une autorité qu'une moitié de son
contenu n'a pas — et c'est précisément la confusion que ce toolkit existe pour empêcher. Un
témoignage utile et étiqueté vaut mieux qu'une mesure inventée ; un témoignage déguisé en mesure ne
vaut rien.

---

## Procédure

1. **`report`** d'abord, toujours. Le plan `instruments` sort en premier et mesure **tes propres
   angles morts** : sans lui, tu ne sais pas ce que vaut le reste.
2. **Lis les `aveugles` avant les `drift`.** Une ligne `unreachable` veut dire que la sonde n'a rien
   pu dire de sa cible. Ce n'est pas un problème de la fleet, c'est un trou dans ta vision — et il
   invalide tout raisonnement qui s'appuierait sur son silence.
3. **Ne conclus jamais au-delà du `cannot_conclude`** de la ligne. Il est obligatoire à l'émission
   précisément parce que c'est la partie qu'on oublie en citant.
4. **Ajoute ton témoignage** dans sa section séparée (ci-dessus).
5. **Transmets.** Si un geste est requis, nomme-le et arrête-toi là.

Pour un rapport archivé : `--out <fichier>.md`. Le markdown porte **toutes** les limites, même sur
les lignes vertes — un rapport relu dans six mois sans elles se lit comme un certificat de bonne
santé.

---

## Ce que le skill ne couvre pas

- **Le plan externe** — paquets, daemons, `/etc`, autres humains, état du conteneur hôte. Un pod
  rapporte la forme de son propre confinement, jamais un inventaire du dehors. Ça, c'est le
  `provision doctor`, qui tourne dehors avec les droits.
- **Le contenu des projets.** Les projets sont des objets : ils existent, ils sont à jour, leur nom
  est pris. Ce qui se passe dedans appartient à l'architecte du projet.
- **La réparation**, cf. la règle en tête.

---

## Extension

Une sonde = un fichier `probes/NN-plan.sh`, un plan, des `emit`. Le contrat de sortie et les
primitives sont dans `probes/lib.sh` ; le rendu ne connaît aucun plan en particulier, un nouveau
apparaît tout seul.

Deux exigences non négociables :

- **`cannot_conclude` obligatoire.** Une sonde incapable d'énoncer sa limite ne rentre pas.
- **Aucune attente écrite en dur quand une déclaration existe à portée.** Le modèle est la
  **liaison** : dire où lire la déclaration, où lire l'observation, et laisser la confrontation être
  le verdict. `60-self` (le cap-profile) et `50-projects` (la source du runtime) sont les deux
  spécimens à copier. Quand aucune déclaration n'existe, on ne l'invente pas : on mesure et on rend
  `unknown`.

Les tests vivent dans `tests/probes.bats` et sont **découverts par le gate** (`shell_gate.sh`). Un
instrument de mesure non mesuré est exactement ce que ce skill existe pour objecter.
