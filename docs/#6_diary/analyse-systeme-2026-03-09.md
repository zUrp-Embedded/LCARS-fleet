# Analyse système LCARS-fleet — protection, monétisation, benchmark

**Date** : 2026-03-09
**Dernière révision** : 2026-03-09
**Statut** : archive — analyse ponctuelle session architect
**Référencé par** : construction-v3.md, backlog #102

_Producteur : architect (Opus). Contexte : analyse complète du système après lecture intégrale de #0 à #4 + construction-v3 + captain_log + fleet-init SKILL.md + provision-system.sh. Questions lordzurp : protection IP, monétisation, benchmarking, stratégie si résultats exceptionnels._

---

## Analyse système

Ce que j'ai en contexte dessine un système avec une propriété rare : **la valeur n'est pas dans le code**. Le bash et le python sont de la plomberie triviale. L'IP réelle est dans :

1. **L'architecture directive** — les L0-L4, les GOs, le protocole, la taxonomie Tier×Division×Knowledge
2. **Le mécanisme d'inférence** — L2 harvest → configuration d'agents adaptée au domaine → amélioration par accumulation
3. **La méthodologie opérationnelle** — comment les agents interagissent, les scopes, les escalades, les handoffs
4. **La récursivité constitutive** — le système se construit avec lui-même, et cette propriété est architecturale, pas accidentelle

Aucun framework analysé (Gas Town, multiclaude, ccswarm, CrewAI, AutoGen) ne fait ça. Ils orchestrent des agents fixes. LCARS génère les agents dont un projet a besoin depuis la connaissance accumulée. C'est un niveau d'abstraction au-dessus.

---

## 1. Risque de réouverture — AGPL

**L'AGPL protège contre le bon risque mais pas contre le vrai.**

- **Risque AWS** (fork → SaaS sans contribuer) : **couvert**. L'AGPL oblige à publier les modifications, y compris en déploiement réseau. C'est exactement son cas d'usage.

- **Risque réel** : quelqu'un lit le repo, comprend la méthodologie (les GOs, la taxonomie, le mécanisme L2, le protocole), et réimplémente from scratch avec du code différent. L'AGPL ne protège pas les idées — elle protège l'implémentation spécifique. Et l'implémentation ici c'est du bash. Le Captain's Log + construction-v3 + les directives sont littéralement un blueprint de réimplémentation.

**Atténuants** :
- La complexité n'est pas dans le code mais dans les **interactions entre directives**. Copier les fichiers ne suffit pas — il faut comprendre pourquoi GO-0 implique GO-7 qui implique le pre-commit hook qui implique le signal de dérive. C'est un réseau de contraintes mutuelles, pas une feature list.
- Le moat réel c'est le **L2 accumulé** — ça ne se copie pas, ça se construit projet après projet.
- La dépendance à Claude Code est structurelle. Quelqu'un qui fork doit recréer tout le binding LLM.
- N=1 actuellement. Avant le PoC, il n'y a rien à voler — juste une architecture prometteuse.

**Recommandation** : rouvrir après PoC 1 validé + au moins un L2 harvest démontré. À ce stade le repo montre "comment" mais pas "avec quoi" (le L2 est privé par construction). Le risque résiduel est acceptable — quelqu'un qui peut réimplémenter LCARS depuis la doc peut probablement l'inventer seul.

**Option dual-licensing** : AGPL pour l'open source + licence commerciale pour les entreprises qui ne veulent pas publier leurs modifications. C'est le modèle GitLab/MongoDB/Grafana. Compatible avec l'AGPL existante.

---

## 2. Monétisation

Soyons honnêtes sur l'état : N=1, pre-PoC, une seule machine. Mais la question est légitime parce que si ça marche, le timing est bon — le marché est en feu.

**Ce qui est monétisable** :

| Modèle | Viabilité | Timing |
|---|---|---|
| **Dual-license** (AGPL + commercial) | Solide — standard industrie | Post-v1 stable |
| **L2 packs domaine** (métier-plugins) | Fort — c'est le vrai produit | Post-harvest validé |
| **Consulting/setup** | Immédiat si demande | Post-PoC |
| **SaaS** | Faible — trop lié à l'environnement local + coût LLM par user | Long terme, si jamais |
| **Formation directive-master** | Niche mais réel | Post-publication |

**Le produit réel n'est pas le code — c'est le L2.** Un `rpi-embedded` L2 mature après 10 projets vaut plus que tout le framework. C'est le modèle "le rasoir est gratuit, les lames se vendent". Le framework est AGPL (rasoir), les L2 packs sont commerciaux (lames).

**Le marché** :
- Cursor/Windsurf/Devin jouent tous sur le single-agent. LCARS est structurellement différent — multi-agent avec mémoire inter-projet.
- L'embedded est sous-servi par tous les outils AI actuels. Niche = moins de concurrence, mais marché plus petit.
- Les entreprises paient pour la **réduction du temps de setup**. Si LCARS fait passer un onboarding projet de 2 semaines à 2 heures via L2, c'est une proposition de valeur chiffrable.

**Risque principal** : dépendance totale à Anthropic/Claude. Si Claude Code change son API, son pricing, ou ses capacités, LCARS est impacté. Pas de mitigation facile — c'est structurel par design (L3 = Claude est le moteur d'inférence).

---

## 3. Comment benchmarker LCARS

C'est la question la plus dure. Aucun benchmark existant (SWE-bench, HumanEval, MBPP) ne teste ce que LCARS fait. Ils testent un agent sur une tâche. LCARS est un méta-système qui génère des agents pour un projet.

**Protocole proposé — 3 axes** :

### Axe 1 — Task completion (comparable)

- Prendre N projets réels (pas des puzzles) : "firmware LED blink sur RPi", "daemon Linux avec API REST", "lib C avec tests"
- Exécuter chaque projet 3 fois : **(a)** Claude Code seul, **(b)** LCARS fleet, **(c)** humain seul (toi, chrono)
- Mesurer : temps total, taux de complétion, nombre d'itérations pour arriver à "tests passent", bugs résiduels

### Axe 2 — L2 accumulation (unique à LCARS)

- 5 projets du même domaine, séquentiels
- Mesurer par projet : temps, escalades, interventions user, qualité code (lint score, test coverage)
- Courbe attendue : décroissance du temps et des interventions → preuve empirique que L2 fonctionne
- C'est **le** benchmark qui différencie LCARS de tout le reste. Si la courbe est plate, le mécanisme L2 ne marche pas.

### Axe 3 — Cross-domain transfer

- Projet dans un domaine nouveau, mais adjacent (L2 rpi-embedded → nouveau projet Arduino)
- Mesurer : le L2 existant aide-t-il ? Comparé à cold start ?

**Métriques concrètes** :
- `T_completion` — minutes du brief au "tests passent"
- `N_escalation` — nombre d'escalades inter-agents
- `N_user_intervention` — nombre de fois où l'user doit corriger/guider
- `Q_code` — ratio tests passés / tests écrits
- `L2_delta` — volume et qualité du L2 harvested post-projet

**Baseline critique** : Claude Code seul avec un bon CLAUDE.md vs LCARS fleet. Si la différence n'est pas significative, la fleet est du overhead sans valeur. La fleet doit battre le single-agent *sur des projets non-triviaux* — sur un hello world, le single-agent gagne forcément (moins d'overhead).

---

## 4. Si les scores explosent

En supposant que l'axe 2 montre une courbe descendante nette (L2 fonctionne) et que l'axe 1 montre un avantage significatif sur les projets non-triviaux :

1. **Reproduire sur une autre machine** — N=1 ne prouve rien. N=2 avec un utilisateur différent, c'est déjà un signal.

2. **arXiv technical report** — pas un paper académique complet (pas le format, pas la rigueur N requis), mais un rapport technique avec : architecture, mécanisme L2, protocole de bench, résultats préliminaires. Ça plante le drapeau. Timestamp public.

3. **Dual-license + réouverture repo** — le rapport arXiv EST la protection intellectuelle (antériorité datée). Rouvrir à ce moment donne de la crédibilité sans risque excessif.

4. **Contacter Anthropic** — un framework multi-agent qui démontre que Claude Code + bonnes directives > tout orchestrateur, c'est un argument de vente pour eux. Partenariat possible : accès API préférentiel, case study, featuring.

5. **Les L2 packs** — si la courbe d'apprentissage est réelle, commencer à builder des L2 `rpi-embedded`, `arduino-fw`, `linux-daemon`. C'est de l'actif qui prend de la valeur avec le temps.

6. **Ne pas lever de fonds trop tôt.** Un arXiv + un repo AGPL + des benchmarks + un domaine de niche = une position défendable. Lever des fonds avant d'avoir N≥3 users diluera pour rien.

---

## 5. arXiv vs HN — stratégie de publication

### arXiv

- Timestamp public irréfutable — antériorité datée, c'est le drapeau planté
- Visibilité académique/recherche — les gens qui lisent arXiv cherchent des mécanismes, pas du produit
- Risque : quasi nul. Un paper arXiv sans code exécutable ni L2 = blueprint théorique. Ceux qui peuvent reimplémenter depuis un paper peuvent inventer seul
- Ça ne génère pas de trafic grand public. Ça génère des citations et de la crédibilité si quelqu'un cherche "multi-agent directive-driven frameworks"
- Timing idéal : post-bench axe 2 (courbe L2 démontrée), même avec N=1

### Hacker News

- Audience complètement différente : devs, founders, VCs, journalistes tech
- Un post HN qui prend = exposition massive en 24h. Milliers de lectures, commentaires, forks du repo
- **C'est un événement irréversible.** Tu ne contrôles pas la réaction. Trois scénarios :
  - **Flop** — personne ne vote, disparaît en 2h. Pas de dommage, pas de gain
  - **Traction modérée** — 50-100 points, commentaires techniques, quelques stars. Bon signal, feedback utile, gérable
  - **Front page** — tout le monde regarde en même temps. Le repo est scruté, les failles exposées, les concurrents alertés. Si le code n'est pas prêt, ça crame la première impression
- Risque concret : les gens HN clonent et lisent le code *le jour même*. Si le repo est ouvert, tout est visible — directives, protocol, méthodologie. Les commentaires HN sont impitoyables sur le code qui ne matche pas les claims
- Risque secondaire : un post HN attire les "aws" — pas Amazon, mais les startups bien financées qui cherchent exactement ce créneau et qui ont 10 devs pour reimplémenter en 2 semaines ce qu'elles trouvent intéressant

### L'ordre compte

```
arXiv d'abord → antériorité établie
         ↓
    bench N≥2 → crédibilité
         ↓
   repo rouvert → code auditable
         ↓
     HN post → exposition
```

Inverser n'importe quelle étape coûte cher. HN avant arXiv = pas d'antériorité. HN avant bench = claims sans preuve. HN avant repo propre = crédibilité cramée.

**Conclusion** : arXiv est safe et utile dès post-PoC + bench. HN est une arme à un coup — on ne la tire qu'une fois, quand tout est aligné.

---

## 6. Règle harvest — Opus obligatoire (backlog #102)

Le harvest L2 (distillation fin de projet L1→L2) DOIT utiliser Opus. Non négociable.

**Raisons** :
1. **Le harvest est un jugement, pas une exécution.** Séparer le généralisable du contextuel, identifier les patterns réutilisables, détecter les faux positifs — c'est du raisonnement profond, pas du pattern matching. Sonnet fait du bon code. Opus fait du bon jugement.
2. **L'erreur est asymétrique.** Un pattern incorrect dans L2 se propage à *tous les projets futurs du domaine* avec haute confiance (experience-following bias). Le coût d'un harvest raté est multiplicatif. Le surcoût Opus est additif et ponctuel (une fois par projet).
3. **C'est le seul point du cycle où l'économie de tokens est contre-productive.** Partout ailleurs, Haiku/Sonnet suffisent. Ici, non.

Curation manuelle user en complément. Opus propose, l'user valide. Même pattern que le curseur 0-10 de `/spec-passe`.
