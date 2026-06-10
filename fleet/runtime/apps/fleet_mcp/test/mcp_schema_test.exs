defmodule Fleet.MCP.SchemaTest do
  @moduledoc """
  Lot 1 — prouve que le canon `priv/config/mcp-channels.yaml` valide contre son
  schema dérivé (`priv/schema/mcp-channels-v1.json`), et que
  `Fleet.MCP.Schema.validate/2` rejette les configs structurellement invalides
  (fail-fast boot). Pattern TDD identique Lot 0bis (PROVEN).

  Z7.3 (2026-06-10) — les cas `mcp-bridge.yaml` retirés avec `Fleet.MCP.Bridge`
  (husk mort, MCP-D1). `Schema.validate/2` reste générique (prouvé sur channels).
  """
  use ExUnit.Case, async: true

  alias Fleet.MCP.Schema

  @channels_schema Path.join([__DIR__, "..", "priv", "schema", "mcp-channels-v1.json"])

  @canon_channels Path.join([__DIR__, "..", "priv", "config", "mcp-channels.yaml"])

  test "fixtures présentes (schema + canon)" do
    assert File.exists?(@channels_schema), "schema absent: #{@channels_schema}"
    assert File.exists?(@canon_channels), "canon absent: #{@canon_channels}"
  end

  test "le canon mcp-channels.yaml valide contre mcp-channels-v1.json" do
    canon = YamlElixir.read_from_file!(@canon_channels)
    assert :ok = Schema.validate(canon, @channels_schema)
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
