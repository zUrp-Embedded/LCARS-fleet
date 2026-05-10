# pipeline-outputs-typing

**Source** : `work/moon-shot/10-beyond/beyond-objets-runtime-v2.md` §3 Invariant 6 "outputs nommés et typés"
**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : DRAFT
**Référencé par** : `objets-runtime/README.md`

## Contrat

Chaque stage déclare ses outputs :
```yaml
outputs:
  - name: diff
    from: git-diff
  - name: report
    from: ~/output/rapport-qualifier.md
    type: report-proven
```

Chaque output a :
- `name` (str, unique dans le stage)
- `from` (source : nom de commande stdlib `git-diff`/`pr-url`, OU chemin fichier `~/output/...`)
- `type` (optionnel, enum : `report-proven`, `report-judged`, `diff`, `branch`, `pr`, ...)

Fleet-pilot :
1. Extrait chaque output du stage terminé selon sa `from`
2. Injecte dans le context du stage suivant via `${{ stages.<name>.outputs.<out> }}`
3. Type-check à l'injection : si le stage aval déclare attendre `type: report-proven`, le stage amont doit produire ce type

## Observable

- Nom unique par stage
- `from: <chemin>` : le fichier existe après extract, sinon FAIL
- `from: <commande>` : commande connue (stdlib restreinte)
- Type check : un `report-judged` ne peut pas être injecté là où un `report-proven` est attendu

## Gaps à combler

- [GAP] Registre des `from` builtins (git-diff, pr-url, branch-name, score)
- [GAP] Registre des `type` autorisés
- [GAP] impl extraction : `extract_output(stage_result, output_spec) -> value`
- [GAP] impl type-check à l'injection : `match_types(expected, actual) -> bool`
- [GAP] test : pipeline 3 stages, output typed avec mauvais type en aval -> rejet
