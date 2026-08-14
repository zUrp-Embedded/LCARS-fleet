defmodule Fleet.EventRouter do
  use Boundary,
    deps: [
      Fleet.Slug,
      Fleet.EnvParse,
      Fleet.GitRef,
      Fleet.Layout,
      Fleet.Event,
      Fleet.SchemaCache,
      Phoenix.PubSub,
      Plug,
      Plug.Builder,
      Plug.Conn,
      Plug.Conn.Unfetched,
      Plug.Conn.WrapperError,
      Plug.Parsers,
      Plug.Router,
      Plug.Router.Utils
    ],
    exports: [Bus, Listener, UnixListener]

  @moduledoc """
  Event registry and PubSub-based event bus. Domains consume events through
  direct subscribers; there is no dispatch table.

  The domain also owns shared HTTP listener construction and the authenticated
  Gitea webhook.
  """
end
