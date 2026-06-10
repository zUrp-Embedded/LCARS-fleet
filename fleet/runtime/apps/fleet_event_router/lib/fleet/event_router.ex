defmodule Fleet.EventRouter do
  @moduledoc """
  Bus events + dispatch table déclarative LCARS v2 (Ring 2 — colonne
  vertébrale orchestration). Voir les sous-modules :

    * `Fleet.EventRouter.Bus` — Phoenix.PubSub instance + broadcast/subscribe
    * `Fleet.EventRouter.WebhooksGitea` — Plug.Router HTTP HMAC SHA256
    * `Fleet.EventRouter.SignalsOS` — `:os.set_signal/2` GenServer
    * `Fleet.EventRouter.Catalog` — charge le registry events.yaml au boot (authorized_event_types). Consommation = subscribers directs (PubSub), pas de table de dispatch (retirée, BL-027)
    * `Fleet.EventRouter.Sanitize.Secrets` / `.PII` — PoC-7 redaction
  """
end
