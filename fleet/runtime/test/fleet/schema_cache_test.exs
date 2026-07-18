defmodule Fleet.SchemaCacheTest do
  @moduledoc """
  `Fleet.SchemaCache` — autorité foundation du pattern « chargé une fois, caché en
  `:persistent_term` » (dédup B-R2).

  `async: true` : `:persistent_term` est un état GLOBAL BEAM, mais chaque test
  utilise une clé UNIQUE (`unique_key/1`) effacée en `on_exit` — pas de collision
  inter-tests, pas de fuite d'entrées.
  """
  use ExUnit.Case, async: true

  alias Fleet.SchemaCache

  # Un JSON-schema minimal mais discriminant (required) : prouve que le résolu
  # est un vrai schema exploitable par le Validator, pas juste une map décodée.
  @schema_json ~s({"type": "object", "required": ["decision"]})

  defp unique_key(label) do
    key = {__MODULE__, label, System.unique_integer([:positive])}
    on_exit(fn -> :persistent_term.erase(key) end)
    key
  end

  defp write_schema!(dir, content) do
    path = Path.join(dir, "schema.json")
    File.write!(path, content)
    path
  end

  describe "resolve_json_schema!/2" do
    @tag :tmp_dir
    test "read+decode+resolve → schema exploitable par le Validator", %{tmp_dir: dir} do
      path = write_schema!(dir, @schema_json)
      key = unique_key(:resolve)

      schema = SchemaCache.resolve_json_schema!(key, path)

      assert %ExJsonSchema.Schema.Root{} = schema
      assert :ok = ExJsonSchema.Validator.validate(schema, %{"decision" => "halt"})
      assert {:error, _} = ExJsonSchema.Validator.validate(schema, %{})
    end

    @tag :tmp_dir
    test "idempotent : un hit ne relit PAS le fichier (supprimé après le 1er appel)",
         %{tmp_dir: dir} do
      path = write_schema!(dir, @schema_json)
      key = unique_key(:idempotent)

      first = SchemaCache.resolve_json_schema!(key, path)
      # Le fichier disparaît : si le 2e appel relisait, il raiserait File.Error.
      File.rm!(path)
      assert SchemaCache.resolve_json_schema!(key, path) == first
    end

    test "fail-loud : fichier absent → File.Error (rien n'est caché)" do
      key = unique_key(:absent)
      path = "/nonexistent/schema-cache-#{System.unique_integer([:positive])}.json"

      assert_raise File.Error, fn -> SchemaCache.resolve_json_schema!(key, path) end
      # L'échec n'a rien caché : fetch! raise toujours « pas chargée ».
      assert_raise ArgumentError, fn -> SchemaCache.fetch!(key) end
    end

    @tag :tmp_dir
    test "fail-loud : JSON malformé → Jason.DecodeError", %{tmp_dir: dir} do
      path = write_schema!(dir, "{not valid json")
      key = unique_key(:malformed)

      assert_raise Jason.DecodeError, fn -> SchemaCache.resolve_json_schema!(key, path) end
    end
  end

  describe "fetch!/2" do
    @tag :tmp_dir
    test "retourne la valeur chargée par resolve_json_schema!/2", %{tmp_dir: dir} do
      path = write_schema!(dir, @schema_json)
      key = unique_key(:fetch_hit)

      loaded = SchemaCache.resolve_json_schema!(key, path)
      assert SchemaCache.fetch!(key) == loaded
    end

    test "clé pas chargée → ArgumentError avec message actionnable (hint boot)" do
      key = unique_key(:fetch_miss)

      err =
        assert_raise ArgumentError, fn ->
          SchemaCache.fetch!(key, "Fleet.Coord.Policies.init_policies!/0")
        end

      assert err.message =~ "not loaded"
      assert err.message =~ "call Fleet.Coord.Policies.init_policies!/0 at boot"
    end

    test "clé pas chargée, sans hint → message générique « init boot-time »" do
      key = unique_key(:fetch_miss_no_hint)

      err = assert_raise(ArgumentError, fn -> SchemaCache.fetch!(key) end)
      assert err.message =~ "the owning app's boot-time init function"
    end
  end

  describe "cached/2" do
    test "lazy sentinel : le fun ne tourne qu'au premier appel" do
      key = unique_key(:cached_once)
      parent = self()

      fun = fn ->
        send(parent, :fun_ran)
        %{"baseline" => ["push --force"]}
      end

      assert %{"baseline" => _} = SchemaCache.cached(key, fun)
      assert_received :fun_ran
      assert %{"baseline" => _} = SchemaCache.cached(key, fun)
      refute_received :fun_ran
    end

    test "un fun qui raise ne cache RIEN — le prochain appel retente" do
      key = unique_key(:cached_raise)

      assert_raise RuntimeError, "boom", fn ->
        SchemaCache.cached(key, fn -> raise "boom" end)
      end

      # Le raise a précédé le put : l'appel suivant exécute bien le fun.
      assert SchemaCache.cached(key, fn -> :recovered end) == :recovered
    end
  end
end
