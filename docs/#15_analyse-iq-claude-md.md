# Analyse — "CLAUDE.md : Le Fichier Secret qui Rend Claude Code 10x Plus Efficace"

**Date** : 2026-03-11
**Dernière révision** : 2026-03-21
**Statut** : analyse ponctuelle — source externe IQ Project
**Référencé par** : #00_index.md

> Ce fichier est un rapport de recherche, pas un guide opérationnel. Emplacement recommandé : `docs/research/`.

Source : https://iq-project.ai/blog/claude-md-fichier-configuration-claude-code-guide-complet
Auteur : IQ Project (bootcamp Vibe Coding). Date article : 19 février 2026.

---

## Résumé de l'article

Guide grand public sur CLAUDE.md avec Claude Code. Orienté débutant à intermédiaire. Couvre la hiérarchie des fichiers, sections recommandées, modularité, auto-mémoire, templates, erreurs courantes, comparaison avec .cursorrules.

---

## Hiérarchie décrite (Anthropic officiel)

| Niveau | Fichier | Portée | Versionné |
|---|---|---|---|
| User Memory | `~/.claude/CLAUDE.md` | tous les projets | non |
| Project Memory | `./CLAUDE.md` | projet entier | oui |
| Project Rules | `./.claude/rules/*.md` | règles modulaires | oui |
| Local Memory | `./CLAUDE.local.md` | projet, personnel | non |
| Auto Memory | `~/.claude/projects/<proj>/memory/` | apprentissage auto | non |

Priorité : plus spécifique > plus général.

---

## Points clés

### @path imports
- Syntaxe `@chemin/fichier` — injecté au démarrage
- Récursif jusqu'à 5 niveaux
- Chemins relatifs résolus par rapport au fichier contenant l'import
- Import dans un bloc de code = ignoré

### .claude/rules/ — règles conditionnelles par chemin
Frontmatter YAML avec `paths:` glob → appliqué uniquement aux fichiers matchant. **Non utilisé dans LCARS actuellement.**

### Auto Memory
- `MEMORY.md` : index. **200 premières lignes chargées au démarrage.**
- Fichiers thématiques : lus à la demande
- `/memory` ouvre en édition

### Limite 80 lignes
Recommandation grand public pour le fichier projet principal. LCARS injecte ~46KB au démarrage — délibéré (context engineering fleet-aware), en contradiction assumée.

---

## Delta LCARS vs article

### Convergences (état au moment de l'analyse — mars 2026)
- **@imports** : LCARS utilise massivement (`@../directives/regles.md`, `@../directives/roles.md`, etc.)
- **Hiérarchie User/Project** : LCARS distingue directives globales (deploy.sh → homes) et directives projet
- **Mémoire thématique** : utilisé avec MEMORY.md + fichiers thématiques

> Note : l'article et cette analyse réfèrent la nomenclature de mars 2026. Certains noms ont évolué depuis (ex: `home_claude_CLAUDE*.md` → architecture `directives/` + `@imports`).

### Ce que l'article apporte
- **`.claude/rules/` path-based** : règles conditionnelles par glob. Potentiellement utile pour différencier les contextes par sous-dossier. **Non implémenté.**
- **CLAUDE.local.md** : préférences non-versionnées. LCARS gère via deploy.sh + profil user.

### Tensions
- **80 lignes vs ~46KB** : LCARS assume explicitement l'injection massive et optimise via techniques documentées dans `#07_token-optimization.md`
- **Auto Memory 200 lignes** : aligné — déjà documenté

---

## Qualité de l'article

**6/10**

Points forts : hiérarchie claire, comparatif .cursorrules, templates concrets.

Limites : orienté débutant, aucune mention hooks/skills/IPC, heuristique "80 lignes" sans source technique Anthropic.

**Intérêt pour LCARS** : confirmation de conformité architecturale. Point d'action : explorer `.claude/rules/` pour différenciation contextuelle par path.

**Décision en attente** : adopter `.claude/rules/` path-based ? Statut : non tranché.
