# Warnings Dialyzer volontairement ignorés → baseline 0 (ratchet). Trois classes AUTORISÉES : (a) code
# GÉNÉRÉ par des macros de deps tierces ; (b) clause générée en source projet (GenServer/@impl) ;
# (c) app OTP que Mix ÉLAGUE du code path et que le code rend présente lui-même à l'exécution
# (`Mix.ensure_application!/1`). Chemins APP-RELATIFS, comme le debug_info du .beam.
# list_unused_filters:true signale une entrée devenue obsolète — on la retire.
[
  # généré par `use ExMCP.Server` (dep) : pattern du dispatch d'outils MCP.
  {"lib/fleet/mcp/pod_tools.ex", :pattern_match},
  # (c) `:cover` vit dans `tools`, app OTP hors des deps que Mix élague du code path : `plt_add_apps`
  # n'ajoute aucun beam (mesuré 2026-09-12). L'outil fait `Mix.ensure_application!(:tools)` avant
  # d'appeler. À retirer avec l'outil, quand le parc sera en OTP ≥ 28.4.
  {"test/support/cover_otp27.ex", :unknown_function}
]
