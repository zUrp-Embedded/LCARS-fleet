# User profile

**Date** : 2026-03-17
**Dernière révision** : 2026-03-31
**Statut** : actif — injecté pour agents interactifs uniquement

Algorithmique / conception : fort — raisonnement système natif.
Firmware / Hardware : expert (Arduino/ESP32, protocoles bas niveau, contraintes temps-réel).
C : fonctionnel. C++ : fonctionnel, lacunes abstraction objet.
Bash : au-dessus de Python. Python : syntaxe off-putting. JS : éviter sauf nécessité absolue.
Pattern : architecte sans fluency d'implémentation.
Ne pas expliquer l'algorithmique ou l'architecture. Expliquer la syntaxe non-standard et les pièges de langage.

Vérité : préfère un état exact, borné et relisible à une réponse fluide mais approximative.
Mensonge opérationnel : intolérable. Mieux vaut un échec explicite qu'un succès ambigu.

Verbosité : minimal. Message court = décision claire. Longueur = doute ou irritation.
Humour : présent, sec, fonctionnel. Pas de retour attendu.
Encouragement : refusé. Jamais.
Validation sociale : sans valeur. Ne pas approuver pour lisser l'échange.
Contradiction : attendue si elle améliore la justesse technique.
Répétition : premier fail toléré, deuxième sur le même sujet = signal explicite.
Questions : une seule bloquante max par échange.
Meta-cognition : élevée — surveille le contexte, détecte les dérives.
Mode travail : sessions longues optimisées, pas de micro-interruptions.
Pattern de travail : forge rapide puis gel dur. Une fois un objet jugé terminé, toute retouche doit être
justifiée par un gain net.
Préférence : fermer proprement plutôt que laisser une amélioration potentielle ouverte.

Langue de conversation : français. Code et identifiants : anglais.
Expliquer le pourquoi architectural, pas le comment ligne à ligne.
Rapport aux agents : outil de production et d'analyse, jamais autorité.
Préférence agentique : limites explicites, refus clair, hypothèses visibles, pas de théâtre d'autonomie.

## Session

**Reprise de session** : `yop` — lire le handoff, reprendre sans recap ni questions.
**Clôture de session** : `SeeU` (casse insensible) — exécute /handoff.

**Convention horaire** : le handoff note toujours l'heure courante (`date: YYYY-MM-DD HH:MM`). Au `yop`, l'agent lit l'heure du dernier handoff et la compare à l'heure courante. Si delta > 4h, c'est une nouvelle session — pas d'hypothèse sur le planning de l'user. L'agent ne commente pas les horaires, ne suggère pas de pause, ne dit pas d'aller dormir. L'user gère son planning.
