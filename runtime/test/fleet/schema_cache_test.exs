defmodule Fleet.SchemaCacheTest do
  @moduledoc """
  `Fleet.SchemaCache` — foundation authority for the "loaded once, cached in
  `:persistent_term`" pattern (B-R2 dedup).

  `async: true`: `:persistent_term` is GLOBAL BEAM state, but each test uses a
  UNIQUE key (`unique_key/1`) erased in `on_exit` — no inter-test collision, no
  leaked entries.
  """
  use ExUnit.Case, async: true

  alias Fleet.SchemaCache

  # A minimal but discriminating JSON-schema (required): proves the resolved value
  # is a real schema usable by the Validator, not just a decoded map.
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
    test "read+decode+resolve → schema usable by the Validator", %{tmp_dir: dir} do
      path = write_schema!(dir, @schema_json)
      key = unique_key(:resolve)

      schema = SchemaCache.resolve_json_schema!(key, path)

      assert %ExJsonSchema.Schema.Root{} = schema
      assert :ok = ExJsonSchema.Validator.validate(schema, %{"decision" => "halt"})
      assert {:error, _} = ExJsonSchema.Validator.validate(schema, %{})
    end

    @tag :tmp_dir
    test "idempotent: a hit does NOT re-read the file (deleted after the 1st call)",
         %{tmp_dir: dir} do
      path = write_schema!(dir, @schema_json)
      key = unique_key(:idempotent)

      first = SchemaCache.resolve_json_schema!(key, path)
      # The file disappears: if the 2nd call re-read, it would raise File.Error.
      File.rm!(path)
      assert SchemaCache.resolve_json_schema!(key, path) == first
    end

    test "fail-loud: missing file → File.Error (nothing cached)" do
      key = unique_key(:absent)
      path = "/nonexistent/schema-cache-#{System.unique_integer([:positive])}.json"

      assert_raise File.Error, fn -> SchemaCache.resolve_json_schema!(key, path) end
      # The failure cached nothing: fetch! still raises "not loaded".
      assert_raise ArgumentError, fn -> SchemaCache.fetch!(key) end
    end

    @tag :tmp_dir
    test "fail-loud: malformed JSON → Jason.DecodeError", %{tmp_dir: dir} do
      path = write_schema!(dir, "{not valid json")
      key = unique_key(:malformed)

      assert_raise Jason.DecodeError, fn -> SchemaCache.resolve_json_schema!(key, path) end
    end
  end

  describe "fetch!/2" do
    @tag :tmp_dir
    test "returns the value loaded by resolve_json_schema!/2", %{tmp_dir: dir} do
      path = write_schema!(dir, @schema_json)
      key = unique_key(:fetch_hit)

      loaded = SchemaCache.resolve_json_schema!(key, path)
      assert SchemaCache.fetch!(key) == loaded
    end

    test "key not loaded → ArgumentError with actionable message (boot hint)" do
      key = unique_key(:fetch_miss)

      err =
        assert_raise ArgumentError, fn ->
          SchemaCache.fetch!(key, "Fleet.Workflow.GateBrief.init_schema!/0")
        end

      assert err.message =~ "not loaded"
      assert err.message =~ "call Fleet.Workflow.GateBrief.init_schema!/0 at boot"
    end

    test "key not loaded, no hint → generic \"boot-time init\" message" do
      key = unique_key(:fetch_miss_no_hint)

      err = assert_raise(ArgumentError, fn -> SchemaCache.fetch!(key) end)
      assert err.message =~ "the owning app's boot-time init function"
    end
  end

  describe "cached/2" do
    test "lazy sentinel: the fun runs only on the first call" do
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

    test "a raising fun caches NOTHING — the next call retries" do
      key = unique_key(:cached_raise)

      assert_raise RuntimeError, "boom", fn ->
        SchemaCache.cached(key, fn -> raise "boom" end)
      end

      # The raise preceded the put: the next call does execute the fun.
      assert SchemaCache.cached(key, fn -> :recovered end) == :recovered
    end

    # 6-002 — LE CHECK-THEN-ACT ECRIVAIT DEUX FOIS. Deux processus qui manquent la meme cle calculent
    # tous les deux, puis ecrivaient tous les deux : un GC GLOBAL de plus (F-001) pour ranger une
    # valeur deja presente, et le terme rendu aux lecteurs precedents remplace pour rien.
    #
    # LA COURSE EST JOUEE SANS CONCURRENCE, et c'est ce qui rend le test deterministe : le `fun`
    # ECRIT LUI-MEME la cle avant de rendre sa valeur. C'est exactement l'etat que voit le perdant
    # au moment de la relecture — quelqu'un a rempli la cle pendant mon calcul. Aucun `spawn`,
    # aucun `sleep`, aucun ordonnancement a esperer.
    test "6-002: la cle deja remplie pendant le calcul n'est pas ecrasee, et c'est SA valeur qui sort" do
      key = unique_key(:cached_race)

      perdant = fn ->
        :persistent_term.put(key, :pose_par_le_gagnant)
        :calcule_par_le_perdant
      end

      assert SchemaCache.cached(key, perdant) == :pose_par_le_gagnant
      assert :persistent_term.get(key) == :pose_par_le_gagnant
    end

    # TEMOIN — sans lui, un `cached/2` qui ne ferait JAMAIS d'ecriture passerait le test ci-dessus.
    test "6-002: TEMOIN — sur une cle vraiment absente, la valeur calculee EST ecrite" do
      key = unique_key(:cached_write)

      assert SchemaCache.cached(key, fn -> :calculee end) == :calculee
      assert :persistent_term.get(key) == :calculee
    end
  end
end
