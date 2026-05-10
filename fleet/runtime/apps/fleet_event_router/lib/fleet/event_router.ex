defmodule Fleet.EventRouter do
  @moduledoc """
  Bus events + dispatch table déclarative LCARS v2 (Ring 2 — colonne
  vertébrale orchestration). Voir les sous-modules :

    * `Fleet.EventRouter.Bus` — Phoenix.PubSub instance + broadcast/subscribe
    * `Fleet.EventRouter.Schema` — JSON schema NDJSON soft validation
    * `Fleet.EventRouter.WebhooksGitea` — Plug.Router HTTP HMAC SHA256
    * `Fleet.EventRouter.SignalsOS` — `:os.set_signal/2` GenServer
    * `Fleet.EventRouter.Dispatch` — table YAML + apply handlers
    * `Fleet.EventRouter.Sanitize.Secrets` / `.PII` — PoC-7 redaction
  """
end
