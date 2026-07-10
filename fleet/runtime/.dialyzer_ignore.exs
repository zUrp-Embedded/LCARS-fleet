# Warnings Dialyzer volontairement ignorés → baseline 0 (ratchet). Deux classes AUTORISÉES, chacune justifiée
# en commentaire ci-dessous : (a) code GÉNÉRÉ par des macros de deps tierces ; (b) clause générée en source
# projet (GenServer/@impl, non actionnable en source). Chemin APP-RELATIF (comme le .beam debug_info interne
# de l'umbrella, pas le préfixe `apps/...` d'affichage). list_unused_filters:true alerte si une entrée devient obsolète.
[
  # généré par `use ExMCP.Server` (dep) : pattern du dispatch d'outils MCP.
  {"lib/fleet/mcp/pod_tools.ex", :pattern_match},
  # clause générée (GenServer/@impl), non actionnable en source.
  {"lib/fleet/spawner/publish_consumer.ex", :pattern_match}
]
