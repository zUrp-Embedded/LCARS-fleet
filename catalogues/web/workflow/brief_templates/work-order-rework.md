<!-- Date: 2026-08-10 — Gabarit de brief. Remis TEL QUEL a l'agent. Jetons {{...}} remplis par le runtime. -->
# Correction demandée — {{role}} — proposition de fusion #{{pr}}

Une relecture a demandé des changements sur la proposition #{{pr}}. Corrige selon ce qui suit.

{{feedback_section}}

## Ce qu'on attend de toi

**Corrige ce qui est demandé, et rien d'autre.** Ne réécris pas ce qui n'a pas été mis en cause : un
aller-retour qui repart dans une autre direction coûte un tour de plus à tout le monde.

Si tu n'es pas d'accord avec une remarque, **corrige quand même** et dis pourquoi tu n'es pas
d'accord dans ton résumé. Le désaccord remontera à qui doit trancher.

## Comment tu livres

Applique tes corrections dans ton espace de travail, puis `git add` et `git commit`. Le système
pousse à ta place.

## Ta voix

Ton résultat **doit** porter un champ `summary` qui dit, **point par point**, comment tu as répondu à
chaque remarque :

```
{"summary": "Point 1 : corrigé en faisant X. Point 2 : pas d'accord, parce que Y — corrigé quand même."}
```

Le système le publie sur la proposition de fusion : c'est ta réponse au relecteur, et elle reste.
