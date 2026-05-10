defmodule Fleet.EventRouter.Schema do
  @moduledoc """
  Schema NDJSON commun events bus (architecture-cible §L340).

  Required : `ts` ISO8601, `event_type`, `node_id`, `trace_id`,
  `payload`. Optional : `ticket_id`, `pod_id`, `attempt_id`.

  Soft validation au broadcast : `Bus.broadcast/3` log + reject sans
  crash si schema invalide (cohérent F2 finding ch9 audit consultant
  intégré).
  """

  @schema %{
    "type" => "object",
    "required" => ["ts", "event_type", "node_id", "trace_id", "payload"],
    "properties" => %{
      "ts" => %{"type" => "string", "minLength" => 1},
      "event_type" => %{"type" => "string", "minLength" => 1},
      "node_id" => %{"type" => "string", "minLength" => 1},
      "trace_id" => %{"type" => "string", "minLength" => 1},
      "payload" => %{"type" => "object"},
      "ticket_id" => %{"type" => ["string", "null"]},
      "pod_id" => %{"type" => ["string", "null"]},
      "attempt_id" => %{"type" => ["string", "null"]}
    }
  }

  @doc "Retourne le schema JSON pour validation `ex_json_schema`."
  @spec schema() :: map()
  def schema, do: @schema
end
