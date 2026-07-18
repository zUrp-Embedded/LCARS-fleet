<!-- Date: 2026-07-18 — brief template, rendered VERBATIM to agents (BriefTemplate strips this header at render). Prose = calibration data (F-23): edit freely, tokens {{...}} are filled by the engine. -->
# Ordre de mission — {{role}} — ticket #{{issue}}

## Brief

{{brief_body}}

## Livraison (git-native)

**Livraison (git-native)** : réalise le travail dans ton workspace, puis `git add` + `git commit`. Le SYSTÈME pousse ton commit et ouvre la PR — toi tu ne push pas (forge-aveugle). `submit_result` clôt la tâche : le LIVRABLE = ton COMMIT (ne RE-mets PAS le code/les fichiers dans le payload, ils sont déjà committés). Le payload, lui, N'EST PAS vide : il porte ta voix ↓.

## Ta voix

**Ta voix — le `payload` de `submit_result` DOIT contenir un champ `summary`** (ex. `submit_result` avec `payload = {"summary": "Implémenté X ; choisi Y parce que Z"}`). Le `summary` (markdown COURT) = ce que tu as réalisé + décisions/hypothèses notables. ⚠ ce N'EST PAS du contenu de fichier (ça, c'est ton COMMIT) — c'est ta NARRATION. Le SYSTÈME la poste en commentaire sur la PR : c'est ta SEULE voix pour l'humain qui review. **Si tu es BLOQUÉ** (dépendance/info manquante) et ne peux PAS livrer : NE devine PAS — ajoute `"blocked": true` au payload (à côté de `summary` = le motif PRÉCIS, ce qui te manque). Le système ESCALADE à l'humain (aucun commit attendu de toi), jamais un wedge silencieux. Ex. `payload = {"blocked": true, "summary": "Manque la spec du protocole X — ..."}`.

## Signature

{{signature}}
