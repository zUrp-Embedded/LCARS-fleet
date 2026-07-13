# N-Squared Matrix — Fleet Script Dependencies

**Date** : 2026-03-28
**Dernière révision** : 2026-03-28
**Statut** : artefact généré — ne pas éditer
**Référencé par** : v6-rings-and-interfaces.md

Generated: 2026-03-28 09:13
Scripts: 116

## Kernel Matrix (16 scripts)

| uses →             | env | bld |  sp | snd | inb | wak | sta | don | adn | inj | dis | pln | scr | lnc |  on | off |
|---                   |---  |---  |---  |---  |---  |---  |---  |---  |---  |---  |---  |---  |---  |---  |---  |---  |
| env                  |  ·  |  ✓  |     |     |     |     |     |     |     |     |     |     |     |     |     |     |
| bld                  |  ✓  |  ·  |     |     |     |     |     |     |     |     |     |     |     |     |     |     |
| sp                   |  ✓  |     |  ·  |     |     |     |     |     |     |     |     |     |     |     |     |     |
| snd                  |  ✓  |     |     |  ·  |  ✓  |  ✓  |     |     |     |     |     |     |     |     |     |     |
| inb                  |  ✓  |     |     |  ✓  |  ·  |  ✓  |     |     |     |     |     |     |     |     |     |     |
| wak                  |  ✓  |     |     |  ✓  |     |  ·  |     |     |     |     |     |     |     |     |     |     |
| sta                  |  ✓  |     |     |     |     |     |  ·  |  ✓  |  ✓  |     |     |     |     |     |     |     |
| don                  |  ✓  |     |     |     |     |     |  ✓  |  ·  |  ✓  |  ✓  |     |     |     |     |     |     |
| adn                  |  ✓  |     |     |     |     |     |  ✓  |  ✓  |  ·  |  ✓  |     |  ✓  |     |     |     |     |
| inj                  |  ✓  |     |     |     |     |     |  ✓  |  ✓  |  ✓  |  ·  |     |     |     |     |     |     |
| dis                  |  ✓  |     |     |  ✓  |     |  ✓  |     |     |     |     |  ·  |  ✓  |     |     |     |     |
| pln                  |  ✓  |     |     |     |     |     |     |     |     |     |  ✓  |  ·  |  ✓  |     |     |     |
| scr                  |  ✓  |     |     |     |     |     |     |     |     |     |  ✓  |  ✓  |  ·  |     |     |     |
| lnc                  |  ✓  |     |     |     |     |  ✓  |     |     |     |     |     |     |     |  ·  |  ✓  |  ✓  |
| on                   |  ✓  |  ✓  |     |     |     |     |  ✓  |     |     |     |     |     |     |  ✓  |  ·  |  ✓  |
| off                  |  ✓  |     |     |     |     |     |     |     |     |     |     |     |     |  ✓  |  ✓  |  ·  |

## Dependency Summary

**env** → bld
**bld** → env
**sp** → env
**snd** → env inb wak
**inb** → env snd wak
**wak** → env snd
**sta** → env don adn
**don** → env sta adn inj
**adn** → env sta don inj pln
**inj** → env sta don adn
**dis** → env snd wak pln
**pln** → env dis scr
**scr** → env dis pln
**lnc** → env wak on off
**on** → env bld sta lnc off
**off** → env lnc on

## Ring boundaries

| Ring | Scripts | Depends on |
|---|---|---|
| 0 (kernel) | env, bld, sp | (self-contained) |
| 1 (IPC) | snd, inb, wak | env inb snd wak  |
| 2 (STATE) | sta, don, adn, inj | adn don env inj pln sta  |
| 3 (WORKFLOW) | dis, pln, scr | dis env pln scr snd wak  |
| 4 (SHELL) | lnc, on, off | bld env lnc off on sta wak  |
