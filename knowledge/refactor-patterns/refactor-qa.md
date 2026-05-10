# Refactor QA — patterns de travail L2

**Date** : 2026-03-14
**Dernière révision** : 2026-03-14
**Statut** : premier draft — à enrichir par harvest
**Référencé par** : —

---

## Règle fondamentale

Tout refactor est ISO fonctionnel par défaut. L'agent qui reçoit un refactor DOIT vérifier la non-regression avant de livrer. Brief explicite contraire requis pour changer le comportement.

---

## Workflow standard refactor

1/ **Cartographier** — comprendre ce que le code fait réellement (pas ce que les commentaires disent)
2/ **Capturer** — tests de caractérisation sur le comportement actuel (bugs inclus)
3/ **Refactorer** — incrémental, un concern par passe. JAMAIS tout en un prompt.
4/ **Vérifier** — cross-analyse v1/v2, diff comportemental, ISO ou rapport d'écarts

---

## Patterns par catégorie

### A/ Transversaux (tout profil)

| Pattern | Description | Piège courant |
|---|---|---|
| Comprendre avant de toucher | L'agent lit et cartographie avant toute modification. Dépendances, flux, code smells. | Refactorer sans avoir compris → casse silencieuse |
| Tests de caractérisation d'abord | Capturer le comportement actuel AVANT refactor. Les tests documentent la réalité, bugs inclus. | Refactorer puis tester → on ne sait pas ce qui a changé |
| Refactor incrémental | Un concern par passe. Extraire, relire le diff, passer au suivant. | Tout refactorer en un prompt → changements incohérents, diff illisible |
| Error handling / logging | Passer de "plante silencieusement" à "plante avec un message utile". | Ajouter des try/catch génériques qui masquent les vrais problèmes |

### B/ Solo dev / freelance

| Pattern | Description | Piège courant |
|---|---|---|
| Production-readiness | Secrets → env vars, error handling HTTP, logging structuré, validation inputs. | Oublier la parité dev/prod (ça marche en local ≠ ça marche déployé) |
| Découpe monolithe | Fichier géant → modules cohérents. Mise à jour des imports, maintien des tests. | Découper par taille au lieu de par responsabilité |
| Modernisation stack | Callbacks → async/await, PHP5 → PHP8, JS → TypeScript. | Changer la syntaxe sans comprendre la sémantique (ex: error propagation en async) |

### C/ Ingénieur hardware (Arduino/ESP32/firmware)

| Pattern | Description | Piège courant |
|---|---|---|
| Génération squelette | L'IA draft, l'ingé corrige. JAMAIS livré sans review humain sur firmware. | Faire confiance au code généré pour du hardware — erreurs logiques fréquentes |
| Portage entre cartes | Adapter libs, pins, périphériques d'une plateforme à l'autre. | Supposer que les APIs sont identiques (ex: analogRead sur ESP32 ≠ Arduino) |
| Ajout couche réseau | WiFi, MQTT, OTA sur un firmware qui marchait en filaire. Boilerplate réseau. | Ignorer les contraintes temps-réel (WiFi stack bloque le loop sur ESP32) |
| Extraction config hardware | Pins, registres, config depuis un sample code vers une structure propre. | Copier des magic numbers sans comprendre le datasheet |

### D/ Non-développeur (VBA, bash, PHP)

| Pattern | Description | Piège courant |
|---|---|---|
| Expliquer puis nettoyer | Bloc par bloc : explication → version nettoyée avec error handling. | Réécrire d'un coup sans vérifier que le comportement est préservé |
| Portage VBA → Python | Manipulation de données : VBA/macro → Python/Pandas. | Supposer que l'ordre des opérations est identique (Excel recalcule, Python non) |
| Error handling scripts | Messages intelligibles, logs, gestion gracieuse des cas d'erreur. | Ajouter des messages qui masquent l'erreur au lieu de la documenter |
| Automatisation workflow | Description en langage naturel → macro/script. Tâches répétitives, règles fixes, données structurées. | Automatiser un workflow mal compris → automatiser le bug |

### E/ Profils complémentaires

| Pattern | Profil | Description | Piège courant |
|---|---|---|---|
| Notebook → pipeline prod | Data/ML | Jupyter 500 cellules, globals partout → module Python importable, tests, logging | Ignorer la reproductibilité et la gestion mémoire sur gros datasets |
| Infra scripts → IaC propre | DevOps | Dockerfile artisanal → multi-stage, Ansible/Terraform accumulé, CI/CD YAML copié-collé | Rationaliser sans comprendre les dépendances d'ordre d'exécution |
| Archéologie codebase héritée | Tech lead | Comprendre l'archi, identifier le code mort, trouver les dépendances cachées — AVANT de toucher | Refactorer avant de comprendre → casser l'inconnu |

### F/ Patterns supplémentaires (tout profil)

| Pattern | Description | Piège courant |
|---|---|---|
| Code mort / élagage | Fonctions jamais appelées, imports inutiles, feature flags obsolètes. Élaguer AVANT de nettoyer. | Supprimer du code qui semble mort mais qui est appelé par réflexion/eval |
| Documentation depuis code | Read-only : ne touche à rien, documente tout. Docstrings, README, diagrammes. | Documenter ce que le code DEVRAIT faire au lieu de ce qu'il FAIT |
| Uniformisation style | Nommage, indentation, patterns. La logique ne change pas, seul le style change. | Changer le style ET la logique dans la même passe → diff illisible |
| Migration framework | Express → Fastify, React class → hooks, Django → FastAPI. Par étapes. | Migrer tout d'un coup au lieu de route par route |
| Hardening / sécurité | Injection SQL, secrets hardcodés, dépendances vulnérables, validation input. | Ajouter de la sécurité qui casse le fonctionnel (ex: validation trop stricte) |
| Batch refactor N fichiers | Même changement mécanique sur N fichiers. Pas de créativité, de la répétition. | Ne pas vérifier que le changement mécanique est correct sur TOUS les cas |
| POC → architecture propre | Monobloc vibe-coded → couches séparées (controller/service/repo). | Sur-architecturer avant d'avoir des utilisateurs |

---

## Matrice profils × patterns

| Use case | Solo Dev | HW Eng | Non-Dev | Data/ML | DevOps |
|---|---|---|---|---|---|
| Comprendre code existant | ●●● | ●● | ●●● | ●● | ●●● |
| Tests de caractérisation | ●●● | ○ | ○ | ●●● | ●● |
| Refactoring incrémental | ●●● | ●● | ● | ●● | ●● |
| Error handling / logging | ●●● | ●● | ●●● | ●●● | ●●● |
| Production-readiness | ●●● | ● | ○ | ●●● | ●● |
| Découpe monolithe | ●●● | ● | ○ | ●●● | ● |
| Modernisation syntax | ●●● | ●● | ●● | ●● | ●● |
| Portage plateforme | ●● | ●●● | ●● | ● | ● |
| Génération boilerplate | ●● | ●●● | ●●● | ●● | ●●● |
| Workflow → code | ● | ● | ●●● | ●● | ●●● |
| Code mort / élagage | ●●● | ● | ● | ●● | ●● |
| Doc depuis code | ●●● | ●● | ● | ●●● | ●●● |
| Uniformisation style | ●●● | ● | ○ | ●● | ●● |
| Migration framework | ●●● | ● | ● | ●● | ●● |
| Hardening / sécurité | ●●● | ● | ●●● | ● | ●●● |
| Batch refactor N fichiers | ●●● | ○ | ○ | ●● | ●●● |
| POC → architecture | ●●● | ●● | ○ | ●●● | ● |

---

## QA refactor — checklist qualifier

1/ Requêtes DB / inputs externes → diff textuel, doivent être IDENTIQUES
2/ Traitement post-input → cross-analyse statique v1/v2 (le LLM trace le flux mentalement)
3/ Outputs → diff des résultats sur données représentatives
4/ Cas limites → dossier vide, fichier absent, input malformé, permissions manquantes
5/ ISO fonctionnel confirmé → PASS. Écart détecté → FAIL + rapport précis des divergences

---

## Sources

Synthèse de patterns documentés sur Reddit (r/ChatGPTCoding, r/ClaudeAI), Hacker News, blogs techniques, forums Arduino/ESP32, Indie Hackers — période 2025-2026.
