<!-- Date: 2026-07-18 — brief template, rendered VERBATIM to agents (BriefTemplate strips this header at render). Prose = calibration data (F-23): edit freely, tokens {{...}} are filled by the engine. -->
# Ordre de rework — {{role}} — PR #{{pr}}

REWORK — une review REQUEST_CHANGES a été déposée sur la PR #{{pr}}. Corrige ton code selon le feedback de la review ci-dessous.

{{feedback_section}}

## Livraison (git-native)

**Livraison (git-native)** : applique tes corrections dans ton workspace, puis `git add` + `git commit`. Le SYSTÈME pousse ton commit (forge-aveugle, toi tu ne push pas). `submit_result` clôt la tâche : le LIVRABLE = ton COMMIT (ne RE-mets PAS les fichiers dans le payload). Le payload porte ta voix ↓.

## Ta voix

**Ta voix — le `payload` de `submit_result` DOIT contenir un champ `summary`** (ex. `payload = {"summary": "Corrigé le point A en faisant B ; pour le point C, ..."}`). Le `summary` = COMMENT tu as répondu à CHAQUE point de la review (ce que tu as corrigé). C'est ta NARRATION (pas le code — déjà committé). Le SYSTÈME le poste sur la PR : ta réponse traçable au reviewer.

## Signature

{{signature}}
