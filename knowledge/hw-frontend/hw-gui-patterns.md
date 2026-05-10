# HW→GUI — patterns de travail L2

**Date** : 2026-03-14
**Dernière révision** : 2026-03-14
**Statut** : premier draft — à enrichir par harvest
**Référencé par** : —

---

## Contexte

L'ingé hardware a un firmware fonctionnel. Il veut une interface pour que d'autres puissent l'utiliser sans terminal série. C'est le pattern "bridge HW→UI" — le point exact où l'ingé sort de sa zone de confort.

---

## Pattern 1 — ESP32 + Web GUI embarquée

### Stacks par friction croissante

| Stack | Friction IA | Notes |
|---|---|---|
| HTML/JS vanilla + LittleFS + ESPAsyncWebServer | Moyenne | L'IA génère bien le frontend, bute sur les contraintes embarqué |
| Svelte compilé via svelteesp32 / esp32-sveltekit | Faible (frontend) / Élevée (build chain) | ~2KB gzippé, idéal ESP32. Pattern émergent. |
| React, Angular, Next.js | **À éviter** | Trop gros pour embarqué. L'IA a un biais fort vers React — corriger explicitement. |

### Pièges documentés (cas réels)

| Piège | Cause | Impact |
|---|---|---|
| `localtime_r` incorrect sur ESP32 | API libc partielle sur ESP-IDF | ~5h de debug |
| Chargement données en mémoire pour filtrage serveur | L'IA ignore les contraintes mémoire ESP32 (~300KB heap) | Crash OOM |
| Réponse chunked avec struct mal défini | Variables locales statiques au lieu d'état dans le struct | Fuites d'état entre requêtes concurrentes |
| Boucles infinies dans code de recherche | L'IA tourne en rond sur les corrections logiques | Il faut indiquer explicitement la variable d'état manquante |
| L'IA génère du React quand on demande du Svelte | Biais d'entraînement vers React | Corriger explicitement, refuser React |

### Règle agent

Le dev qui reçoit une tâche ESP32+GUI DOIT vérifier : heap disponible, taille du bundle, concurrence AsyncWebServer, watchdog. L'IA est bonne pour le HTML/CSS/JS, médiocre à dangereuse sur les contraintes embarqué.

---

## Pattern 2 — Raspberry Pi + Dashboard local

### Stacks par friction croissante

| Stack | Friction IA | Notes |
|---|---|---|
| Node-RED | N/A | Pas besoin d'IA — c'est déjà du no-code. IA utile uniquement pour les function nodes JS. |
| Flask + Chart.js | **Faible — sweet spot** | L'ingé connaît Python, Flask est minimal, l'IA génère routes + templates + graphiques. |
| Grafana + InfluxDB + Prometheus | Élevée (config infra) | L'IA aide sur les exporters Python, pas sur la config infra (systemd, réseau, certs). |

### Règle agent

La partie que l'IA gère mal = plumbing système (systemd units, permissions GPIO, config réseau, certificats SSL). Séparer frontend (dev) et infra (starfleet/devops).

---

## Pattern 3 — App mobile pour contrôle hardware

### Réalité terrain

L'ingé HW ne demande PAS à l'IA de générer du Flutter/React Native. Il utilise du no-code :

| Solution | Profil | IA nécessaire ? |
|---|---|---|
| Blynk | Solution de facto ESP32→mobile | Non — IA uniquement côté ESP32 (librairie Blynk) |
| MIT App Inventor | Éducation/hobbyiste | Non — blocks visuels |
| Flutter/React Native via IA | Solo dev/founder, PAS ingé HW | Oui mais BLE/permissions = enfer |

### Piège majeur

L'IA génère facilement une jolie UI mobile. La partie BLE/serial/MQTT côté mobile est un terrain miné (permissions Android, background services, reconnection BLE). Les solutions no-code gagnent ici.

---

## Pattern 4 — Dashboard desktop pour device USB/série

### Stack dominant : Python + tkinter + pyserial

L'IA est particulièrement efficace : tkinter est bien couvert dans le training, les patterns sont répétitifs (layout → widgets → event loop → serial read thread), résultat immédiatement testable.

### Pièges

| Piège | Cause | Fix |
|---|---|---|
| Threading série/GUI | L'IA fait des widget.config() depuis le thread série — tkinter pas thread-safe | Utiliser root.after() ou queue.Queue |
| pyserial Windows vs Linux | Comportements différents sur les ports COM | Tester sur les deux, l'IA ne distingue pas toujours |
| tkinter limité pour dashboards ambitieux | L'IA reste sur tkinter par défaut | Suggérer PyQt ou Dear ImGui pour du temps-réel fluide |

---

## Matrice — stack × contexte

| Contexte | Stack qui marche avec l'IA | Stack à éviter | Friction |
|---|---|---|---|
| ESP32 web GUI simple | HTML/JS vanilla + LittleFS | React, SPA lourds | Moyenne |
| ESP32 web GUI moderne | Svelte compilé (svelteesp32) | Angular, Next.js | Faible→Élevée |
| RPi dashboard | Flask + Chart.js | Config Grafana (infra) | Faible |
| RPi monitoring | Node-RED | Stack Docker custom | N/A |
| App mobile | Blynk | Flutter/RN avec BLE | Élevée |
| Desktop série | Python tkinter + pyserial | Electron | Faible |

---

## Pattern transversal

L'ingé hardware demande rarement à l'IA de créer une GUI from scratch sur un framework inconnu. Il demande du HTML vanilla (qu'il peut lire et corriger), du Python tkinter (son langage secondaire), ou utilise un outil no-code (Blynk, Node-RED, Grafana). Le "vibe coding" d'une interface moderne (Svelte, React) sur ESP32 reste un pattern early adopter.

---

## Sources

Synthèse de patterns réels : Reddit (r/esp32, r/arduino, r/ClaudeAI), HN, RandomNerdTutorials, forums Arduino/ESP32, blogs techniques embedded — période 2024-2026.
