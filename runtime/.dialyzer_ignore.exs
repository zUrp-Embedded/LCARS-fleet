# Warnings Dialyzer volontairement ignorés → baseline 0 (ratchet). Trois classes AUTORISÉES, chacune justifiée
# en commentaire ci-dessous : (a) code GÉNÉRÉ par des macros de deps tierces ; (b) clause générée en source
# projet (GenServer/@impl, non actionnable en source) ; (c) app OTP que Mix ÉLAGUE du code path et que le
# code rend présente lui-même à l'exécution (`Mix.ensure_application!/1`). Chemin APP-RELATIF, comme le
# debug_info du .beam et non le préfixe d'affichage. list_unused_filters:true alerte si une entrée devient obsolète.
[
  # généré par `use ExMCP.Server` (dep) : pattern du dispatch d'outils MCP.
  {"lib/fleet/mcp/pod_tools.ex", :pattern_match},
  # (c) `:cover` vit dans `tools`, app OTP hors des deps : Mix l'élague du code path, dialyxir résout
  # chaque module par `:code.where_is_file/1` sur ce path, donc `plt_add_apps: [:tools]` ajoute ZÉRO
  # beam en le listant comme présent (mesuré 2026-09-12 : `--plt_info` sans un fichier tools-4.1.1).
  # L'outil fait `Mix.ensure_application!(:tools)` avant d'appeler — le geste de Mix lui-même pour
  # `mix test --cover`. À retirer avec l'outil, quand le parc est en OTP ≥ 28.4.
  {"test/support/cover_otp27.ex", :unknown_function}
  # (Une entrée qui devient obsolète parce que le code sous-jacent a été corrigé est le ratchet qui
  # fait son travail : `list_unused_filters` la signale, on la retire.)
]
