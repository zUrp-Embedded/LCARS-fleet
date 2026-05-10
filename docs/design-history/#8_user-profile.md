# Profil utilisateur — modèle à deux couches

**Date** : 2026-03-08
**Dernière révision** : 2026-03-08
**Statut** : spec active — concept + implémentation
**Référencé par** : #3_system-conventions.md (suffixe -standard)

---

## Concept

Deux couches distinctes qui calibrent le comportement agent :

**Profil technique** (fond) — niveau d'expertise, langages maîtrisés, domaines. Répond à : *quoi détailler, quoi supposer acquis*.

**Profil psychologique** (forme) — style de communication, verbosité, humour, tolérance. Répond à : *comment le dire, quel ton, quelle densité*.

Les deux sont indépendants. Un expert peut être verbeux. Un débutant peut être sec. Ne jamais inférer l'un depuis l'autre.

---

## Template standard

Profil par défaut pour tout onboarding sans profil préexistant.
Sémantique : **"discussion entre professionnels du métier"**.

```
# Profil technique — standard
algorithmique: compétent (lit pseudocode, comprend structures de données)
langages: CLI/git/devops literacy assumed. Stack traces lisibles.
termes techniques: pas de définition sauf demande explicite.
tests: compétence de base supposée (pytest, assert, CI/CD concepts).

# Profil psychologique — standard
verbosité: moyenne. Explications concises, pas de hand-holding.
ton: direct, professionnel. Pas d'encouragement.
humour: neutre — ni imposé, ni refusé.
questions multiples: acceptable en onboarding, à réduire ensuite.
```

---

## Profil user — exemple de référence

### Profil technique

| Domaine | Niveau | Notes |
|---|---|---|
| Algorithmique / conception | Fort | Raisonnement architectural natif. Point fort explicite. |
| Firmware / Hardware | Expert | Arduino/ESP32, protocoles bas niveau, contraintes temps-réel. |
| C | Fonctionnel | Écrit et lit sans friction. |
| C++ | Fonctionnel avec lacunes | Abstraction objet non formée (pas de formation académique, siècle dernier). Pas de templates avancés. |
| Bash | Au-dessus de Python | Connaît, utilise, considère comme une purge. System-dependent = cauchemar assumé. |
| Python | Extraction algorithmique seulement | Lit l'algo sous-jacent, syntaxe off-putting (même niveau de rejet que JS). Ne choisit pas Python par plaisir. |
| JS | Rebut | Éviter sauf nécessité absolue. |

**Pattern dominant** : architecte sans fluency d'implémentation. Forte vision système, langages = outil, pas domaine d'expertise. L'agent comble l'écart syntaxe/implémentation — c'est là que la combinaison est maximalement efficace.

**Implication agent** : ne pas expliquer les patterns algorithmiques ou les décisions d'architecture. Expliquer la syntaxe spécifique si non-standard. Détailler les pièges de langage (Python gotchas, C++ UB, Bash portabilité) sans détailler la logique sous-jacente.

### Profil psychologique

| Dimension | Valeur | Signal observable |
|---|---|---|
| Verbosité | Minimal | Messages courts = décisions claires. Longueur = doute ou irritation. |
| Humour | Présent, sec, fonctionnel | "c'est pour un ami", "pour draguer en boite". Pas de retour attendu. |
| Tolérance répétition | Nulle | Premier fail : ok. Deuxième sur le même sujet : signal explicite. |
| Encouragement | Refusé | Jamais. |
| Questions multiples | Refusées | Une question bloquante max. |
| Meta-cognition | Élevée | Surveille le contexte, détecte les dérives avant qu'elles deviennent bugs. |
| Mode de travail | Sessions longues optimisées | Pas d'interruptions, substrat énergétique en place avant de démarrer. |
| Relation au code | Architecte-utilisateur | Valide la structure, délègue l'implémentation. |

---

## Où ça vit

| Couche | Fichier | Notes |
|---|---|---|
| Profil psychologique | `.claude/CLAUDE.md` — section "User profile" | Stable, change rarement, mise à jour consciente uniquement. |
| Profil technique | `.claude/CLAUDE.md` — section "User profile" | Overridable par projet si contexte change. |
| Template standard | `#8_user-profile.md` (ce fichier, § Template standard) | Copié à l'onboarding si aucun profil existant. |

---

## Où c'est utilisé

**First Contact Protocol** — step 0 : charger le profil utilisateur avant la première interaction. Sans profil : appliquer le template standard, observer, affiner.

**Calibration ton** — profil psychologique → ajuster densité, longueur, humour, questions.

**Calibration détail** — profil technique → supposer acquis / expliquer selon le domaine. L'agent ne ré-explique pas ce qui est dans la colonne "Expert" du profil.

**Détection de dérive** — un agent qui over-explique à un expert, ou qui under-explique à un débutant, dévie du profil. C'est un signal de drift context ou de profil mal chargé, pas un bug de comportement isolé.

**Génération CLAUDE.md** — au provisioning, le profil user alimente la section "User profile" du CLAUDE.md instance.

---

---

## Notes — companion narratif

# Notes — #8_user-profile.md

**Date** : 2026-03-10
**Statut** : companion narratif du fichier canonique
**Fichier canonique** : `#8_user-profile.md` (seul fichier faisant foi)

> Ce fichier est une version narrative et explicative. Il n'est pas injecté, pas dérivé, pas normatif.
> Toute règle ou contrainte doit vivre dans le fichier canonique. Ce fichier documente le *pourquoi*,
> stocke le changelog, et capture les discussions de refonte.

---

## Changelog version canonique

| Date | Nature | Détail |
|------|--------|--------|
| 2026-03-08 | Création | Modèle deux couches (technique + psychologique) |
| 2026-03-10 | Audit v2 | `user-profile-technical.md` référencé mais inexistant, profil lordzurp inline = spec de facto pas un exemple, `lordzurp` en dur viole règle noms propres |
| 2026-03-11 | Nettoyage v2 | `lordzurp` → `user`. Référencé par corrigé. L3/L4 retirés. Sections inférence → notes (aspirationnel). SPEC-USR-002 retiré (artefact specs). |

---

## Contenu retiré du canonique

### Section "Inférence du profil technique" (aspirationnel)

Le profil technique peut être inféré en ~10 minutes d'échanges réels. Pas de questionnaire formel nécessaire.

**Signaux expert** :
- Répond aux plans avec sélection numérotée sans demander d'explication
- Corrige des décisions architecturales, pas des syntaxes
- Utilise le vocabulaire du domaine sans y être invité
- Formule des bugs en termes de comportement système, pas d'erreur

**Signaux débutant** :
- Demande la définition de termes courants (I2C vs UART, git rebase vs merge)
- Valide chaque étape avant de passer à la suivante
- Corrige la forme ("je n'ai pas compris") plutôt que le fond

**Protocole d'inférence** : l'agent d'onboarding observe les 5 premiers échanges, écrit un draft de profil technique dans `user-profile-technical.md`, le soumet à l'utilisateur pour correction. Un seul aller-retour.

### Section "Inférence du profil psychologique" (aspirationnel)

Nécessite ~1-2h de conversation naturelle. Ne pas le déduire prématurément.

**À observer** : longueur moyenne des messages, présence/absence d'humour, réaction aux récaps non demandés, tolérance aux questions, mode de correction (ton neutre vs irritation signalée).

**Protocole** : écrit par architect après observation, pas par un agent d'onboarding automatique. Le profil psychologique est subjectif — il nécessite un interlocuteur humain pour validation.
