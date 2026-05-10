# Knowledge L2 — Embedded

**Date** : 2026-03-28
**Dernière révision** : 2026-03-28
**Statut** : bootstrap
**Référencé par** : v6-rings-and-interfaces.md

## Sources

| Fichier | Source | Licence | Usage |
|---|---|---|---|
| arm-cortex-expert.md | [wshobson/agents](https://github.com/wshobson/agents) plugin arm-cortex-microcontrollers | MIT | Agent definition, knowledge base ARM Cortex-M embedded patterns |

## Contenu

- ARM Cortex-M0/M0+/M3/M4/M7 patterns
- Memory barriers MMIO (DMB/DSB), DMA cache coherency
- Interrupt priorities, critical sections, NVIC
- Peripheral drivers (SPI/I2C/UART/CAN/USB)
- FreeRTOS/Zephyr integration patterns
- Safety-critical patterns (stack overflow, hardfault debug, FPU context)
- C/C++17 et Rust patterns

## Roadmap

- [ ] MISRA-C subset (top 20 rules pour embedded)
- [ ] ISR safety checklist (volatile, no-malloc, atomic access)
- [ ] Memory patterns (pool allocator, ring buffer, stack-only)
- [ ] CAN/SPI/I2C protocol patterns (timing, error recovery)
- [ ] Checklist review embedded (pour qualifier/reviewer)
