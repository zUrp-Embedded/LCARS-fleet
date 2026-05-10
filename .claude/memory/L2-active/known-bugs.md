---
date: 2026-03-08
projet_source: ruflo
ci_hash: abc1234
hits: 3
---
# Known bugs — rpi-embedded
## Pattern: losetup -P fails on WSL2
**Fix**: use mount -o loop,offset=
