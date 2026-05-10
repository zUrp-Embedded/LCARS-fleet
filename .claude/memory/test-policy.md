# Test policy

| Context | Approach |
|---|---|
| One-shot scripts | No tests. Manual verification steps if useful. |
| Durable Python scripts | Unit tests on critical functions (algorithms, parsing). pytest. |
| Arduino/ESP32 firmware | No automated tests. Provide hardware validation checklist. |

Run existing tests before declaring work complete.
If captured behaviour looks like a bug, raise it before continuing.
