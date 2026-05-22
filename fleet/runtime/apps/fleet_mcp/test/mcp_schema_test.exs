defmodule Fleet.MCP.SchemaTest do
  @moduledoc """
  Lot 1 — prouve que les configs canon `05_data-canon/config/mcp-channels.yaml`
  et `mcp-bridge.yaml` valident contre leurs schemas dérivés
  (`priv/schema/mcp-channels-v1.json` / `mcp-bridge-v1.json`), et que
  `Fleet.MCP.Schema.validate/2` rejette les configs structurellement invalides
  (fail-fast boot). Pattern TDD identique Lot 0bis (PROVEN).
  """
  use ExUnit.Case, async: true

  alias Fleet.MCP.Schema

  @channels_schema Path.join([__DIR__, "..", "priv", "schema", "mcp-channels-v1.json"])
  @bridge_schema Path.join([__DIR__, "..", "priv", "schema", "mcp-bridge-v1.json"])

  @canon_channels Path.join([
                    __DIR__,
                    "..",
                    "..",
                    "..",
                    "..",
                    "..",
                    "05_data-canon",
                    "config",
                    "mcp-channels.yaml"
                  ])
  @canon_bridge Path.join([
                  __DIR__,
                  "..",
                  "..",
                  "..",
                  "..",
                  "..",
                  "05_data-canon",
                  "config",
                  "mcp-bridge.yaml"
                ])

  test "fixtures présentes (schemas + canon)" do
    assert File.exists?(@channels_schema), "schema absent: #{@channels_schema}"
    assert File.exists?(@bridge_schema), "schema absent: #{@bridge_schema}"
    assert File.exists?(@canon_channels), "canon absent: #{@canon_channels}"
    assert File.exists?(@canon_bridge), "canon absent: #{@canon_bridge}"
  end

  test "le canon mcp-channels.yaml valide contre mcp-channels-v1.json" do
    canon = YamlElixir.read_from_file!(@canon_channels)
    assert :ok = Schema.validate(canon, @channels_schema)
  end

  test "le canon mcp-bridge.yaml valide contre mcp-bridge-v1.json" do
    canon = YamlElixir.read_from_file!(@canon_bridge)
    assert :ok = Schema.validate(canon, @bridge_schema)
  end

  test "channels : transport hors enum rejeté (fail-fast)" do
    bad = %{
      "channels" => %{
        "fleet-control" => %{
          "description" => "x",
          "transport" => ["carrier_pigeon"],
          "sub_topics" => ["fleet-control.coord.*"]
        }
      }
    }

    assert {:error, [_ | _]} = Schema.validate(bad, @channels_schema)
  end

  test "channels : clé requise manquante rejetée" do
    bad = %{"channels" => %{"fleet-forge" => %{"description" => "x"}}}
    assert {:error, errors} = Schema.validate(bad, @channels_schema)
    assert is_list(errors) and errors != []
  end

  test "channels : propriété inconnue rejetée (additionalProperties:false)" do
    bad = %{
      "channels" => %{
        "fleet-control" => %{
          "description" => "x",
          "transport" => ["stdio"],
          "sub_topics" => ["fleet-control.coord.*"],
          "rogue_key" => true
        }
      }
    }

    assert {:error, [_ | _]} = Schema.validate(bad, @channels_schema)
  end

  test "bridge : direction requise manquante rejetée" do
    bad = %{"bridges" => %{"mcp_to_pubsub" => [%{}]}}
    assert {:error, [_ | _]} = Schema.validate(bad, @bridge_schema)
  end

  test "bridge : item mcp_to_pubsub incomplet rejeté" do
    bad = %{
      "bridges" => %{
        "mcp_to_pubsub" => [%{"mcp_channel" => "fleet-control.*"}],
        "pubsub_to_mcp" => [
          %{
            "pubsub_topic" => "fleet.events",
            "event_type" => "coord.action.*",
            "mcp_channel_template" => "fleet-control.{target_role}.coord"
          }
        ]
      }
    }

    assert {:error, [_ | _]} = Schema.validate(bad, @bridge_schema)
  end

  test "schema introuvable → erreur taggée, pas d'exception" do
    assert {:error, [msg]} = Schema.validate(%{}, "/nonexistent/schema.json")
    assert msg =~ "indisponible"
  end

  # F5 reviewer Lot 1 #558 : data non-map (YAML mal formé → liste/scalaire)
  # → erreur taggée, PAS FunctionClauseError (contrat @moduledoc honoré).
  test "data non-map → erreur taggée, pas d'exception" do
    assert {:error, [m1]} = Schema.validate([:not, :a, :map], @channels_schema)
    assert m1 =~ "map attendue"
    assert {:error, [_]} = Schema.validate("scalar", @channels_schema)
  end

  test "priv_schema/1 résout sous l'app fleet_mcp" do
    path = Schema.priv_schema("mcp-channels-v1.json")
    assert String.ends_with?(path, "priv/schema/mcp-channels-v1.json")
  end
end
