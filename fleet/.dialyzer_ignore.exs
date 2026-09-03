# Warnings Dialyzer volontairement ignorés → baseline 0 (ratchet). Deux classes AUTORISÉES, chacune justifiée
# en commentaire ci-dessous : (a) code GÉNÉRÉ par des macros de deps tierces ; (b) clause générée en source
# projet (GenServer/@impl, non actionnable en source). Chemin APP-RELATIF, comme le debug_info du
# .beam et non le préfixe d'affichage. list_unused_filters:true alerte si une entrée devient obsolète.
[
  # généré par `use ExMCP.Server` (dep) : pattern du dispatch d'outils MCP.
  {"lib/fleet/mcp/pod_tools.ex", :pattern_match}
  # (Une entrée qui devient obsolète parce que le code sous-jacent a été corrigé est le ratchet qui
  # fait son travail : `list_unused_filters` la signale, on la retire.)
]
