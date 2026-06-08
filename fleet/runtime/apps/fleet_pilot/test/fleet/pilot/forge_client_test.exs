defmodule Fleet.Pilot.ForgeClientTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.ForgeClient

  # Plug stub Req — intercepte les requêtes en mémoire, pas de réseau.
  # Pattern Req standard (option `:plug`). Toutes les routes attendues
  # matched explicitement ; un fallback 500 force un test à expliciter
  # son path (pas de "any" silencieux).
  defmodule FakeForge do
    @behaviour Plug

    @impl Plug
    def init(handlers), do: handlers

    @impl Plug
    def call(conn, handlers) do
      key = {conn.method, conn.request_path}

      case Map.fetch(handlers, key) do
        {:ok, {status, body}} ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.send_resp(status, JSON.encode!(body))

        :error ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.send_resp(
            500,
            JSON.encode!(%{error: "no handler for #{conn.method} #{conn.request_path}"})
          )
      end
    end
  end

  defp opts(handlers) do
    [
      base_url: "http://fake.test",
      token: "fake-token",
      req_options: [plug: {FakeForge, handlers}]
    ]
  end

  describe "add_label/4 — happy paths" do
    test "ajoute le label quand il n'est pas présent" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} => {200, []},
        {"GET", "/api/v1/repos/fleet/lcars/labels"} =>
          {200, [%{"id" => 7, "name" => "lcars-dispatched"}]},
        {"PUT", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200, [%{"id" => 7, "name" => "lcars-dispatched"}]}
      }

      assert {:ok, :added} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", opts(handlers))
    end

    test "préserve les labels existants en PUT (pattern v1.5 GET+PUT)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200, [%{"id" => 3, "name" => "type:poc"}, %{"id" => 4, "name" => "state:open"}]},
        {"GET", "/api/v1/repos/fleet/lcars/labels"} =>
          {200,
           [
             %{"id" => 3, "name" => "type:poc"},
             %{"id" => 4, "name" => "state:open"},
             %{"id" => 7, "name" => "lcars-dispatched"}
           ]},
        {"PUT", "/api/v1/repos/fleet/lcars/issues/42/labels"} => {200, []}
      }

      assert {:ok, :added} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", opts(handlers))
    end

    test "no-op si label déjà présent (zéro round-trip d'écriture)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200, [%{"id" => 7, "name" => "lcars-dispatched"}]}
      }

      # Pas de handler PUT ni labels-index → si appelé, fallback 500
      # ferait crash. Le test valide implicitement qu'on ne tape pas.
      assert {:ok, :already_present} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", opts(handlers))
    end
  end

  describe "add_label/4 — error paths" do
    test "label inconnu dans le repo" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} => {200, []},
        {"GET", "/api/v1/repos/fleet/lcars/labels"} => {200, []}
      }

      assert {:error, {:label_unknown, "lcars-dispatched"}} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", opts(handlers))
    end

    test "HTTP non-2xx sur GET issue labels (ex 404)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/9999/labels"} =>
          {404, %{"message" => "Not Found"}}
      }

      assert {:error, {:http, 404, _}} =
               ForgeClient.add_label("fleet/lcars", 9999, "lcars-dispatched", opts(handlers))
    end

    test "HTTP 401 sur token invalide" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} => {401, %{"message" => "auth"}}
      }

      assert {:error, {:http, 401, _}} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", opts(handlers))
    end
  end

  describe "list_open_issues_without_label/3" do
    test "filtre client-side les issues avec le label exclu" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues"} =>
          {200,
           [
             %{
               "number" => 1,
               "title" => "Issue dispatchable",
               "labels" => [%{"name" => "type:poc"}]
             },
             %{
               "number" => 2,
               "title" => "Issue déjà dispatchée",
               "labels" => [%{"name" => "type:poc"}, %{"name" => "lcars-dispatched"}]
             },
             %{
               "number" => 3,
               "title" => "Autre dispatchable",
               "labels" => []
             }
           ]}
      }

      assert {:ok, [%{"number" => 1}, %{"number" => 3}]} =
               ForgeClient.list_open_issues_without_label(
                 "fleet/lcars",
                 "lcars-dispatched",
                 opts(handlers)
               )
    end

    test "renvoie liste vide si toutes les issues ont le label exclu" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues"} =>
          {200,
           [
             %{"number" => 1, "labels" => [%{"name" => "lcars-dispatched"}]},
             %{"number" => 2, "labels" => [%{"name" => "lcars-dispatched"}]}
           ]}
      }

      assert {:ok, []} =
               ForgeClient.list_open_issues_without_label(
                 "fleet/lcars",
                 "lcars-dispatched",
                 opts(handlers)
               )
    end

    test "propage erreurs HTTP" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues"} =>
          {503, %{"message" => "Service Unavailable"}}
      }

      assert {:error, {:http, 503, _}} =
               ForgeClient.list_open_issues_without_label(
                 "fleet/lcars",
                 "lcars-dispatched",
                 opts(handlers)
               )
    end
  end

  describe "add_label/4 — config" do
    test "manque base_url → {:error, {:config, {:missing, :base_url}}}" do
      assert {:error, {:config, {:missing, :base_url}}} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", token: "t")
    end

    @tag :tmp_dir
    test "token lu depuis token_file (trim newline)", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "gitea_token")
      File.write!(path, "secret-token-from-file\n")

      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200, [%{"id" => 7, "name" => "lcars-dispatched"}]}
      }

      opts = [
        base_url: "http://fake.test",
        token_file: path,
        req_options: [plug: {FakeForge, handlers}]
      ]

      assert {:ok, :already_present} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", opts)
    end

    @tag :tmp_dir
    test "token_file absent → {:error, {:config, {:token_file, _, :enoent}}}",
         %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "absent_token")

      opts = [base_url: "http://fake.test", token_file: path]

      assert {:error, {:config, {:token_file, ^path, :enoent}}} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", opts)
    end

    test "trim trailing slash sur base_url" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200, [%{"id" => 7, "name" => "lcars-dispatched"}]}
      }

      opts = [
        base_url: "http://fake.test/",
        token: "t",
        req_options: [plug: {FakeForge, handlers}]
      ]

      assert {:ok, :already_present} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", opts)
    end
  end

  # ============================================================
  # Write-ops (primitives de fin-de-hop, DN forge-state-machine §5)
  # ============================================================

  describe "set_assignee/4" do
    test "PATCH l'assignee quand différent" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42"} =>
          {200, %{"assignees" => [%{"login" => "Engineer"}]}},
        {"PATCH", "/api/v1/repos/fleet/lcars/issues/42"} => {201, %{}}
      }

      assert {:ok, :set} =
               ForgeClient.set_assignee("fleet/lcars", 42, "Qualifier", opts(handlers))
    end

    test "no-op si déjà le seul assignee (idempotent)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42"} =>
          {200, %{"assignees" => [%{"login" => "Qualifier"}]}}
      }

      assert {:ok, :already} =
               ForgeClient.set_assignee("fleet/lcars", 42, "Qualifier", opts(handlers))
    end
  end

  describe "set_state_label/4" do
    test "retire l'ancien state:* et pose le nouveau, conserve les autres labels" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200,
           [
             %{"id" => 3, "name" => "type:poc"},
             %{"id" => 9, "name" => "lcars-in-flight"},
             %{"id" => 4, "name" => "state:dispatched"}
           ]},
        {"GET", "/api/v1/repos/fleet/lcars/labels"} =>
          {200,
           [
             %{"id" => 3, "name" => "type:poc"},
             %{"id" => 9, "name" => "lcars-in-flight"},
             %{"id" => 4, "name" => "state:dispatched"},
             %{"id" => 5, "name" => "state:judged"}
           ]},
        {"PUT", "/api/v1/repos/fleet/lcars/issues/42/labels"} => {200, []}
      }

      assert {:ok, :set} =
               ForgeClient.set_state_label("fleet/lcars", 42, "state:judged", opts(handlers))
    end
  end

  describe "post_comment/4 — dédup signature" do
    test "poste si la signature est absente" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} => {200, []},
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/comments"} => {201, %{"id" => 1}}
      }

      assert {:ok, :posted} =
               ForgeClient.post_comment(
                 "fleet/lcars",
                 42,
                 "[hop:engineer:abc] livrable",
                 Keyword.merge(opts(handlers), dedup_signature: "[hop:engineer:abc]")
               )
    end

    test "no-op si la signature existe déjà (idempotent replay)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} =>
          {200, [%{"body" => "déjà là [hop:engineer:abc] livrable"}]}
      }

      assert {:ok, :already} =
               ForgeClient.post_comment(
                 "fleet/lcars",
                 42,
                 "[hop:engineer:abc] livrable",
                 Keyword.merge(opts(handlers), dedup_signature: "[hop:engineer:abc]")
               )
    end
  end

  describe "remove_label/4 + close_issue/3" do
    test "remove_label : no-op si absent" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} => {200, []}
      }

      assert {:ok, :already_absent} =
               ForgeClient.remove_label("fleet/lcars", 42, "lcars-in-flight", opts(handlers))
    end

    test "remove_label : DELETE quand présent" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200, [%{"id" => 9, "name" => "lcars-in-flight"}]},
        {"GET", "/api/v1/repos/fleet/lcars/labels"} =>
          {200, [%{"id" => 9, "name" => "lcars-in-flight"}]},
        {"DELETE", "/api/v1/repos/fleet/lcars/issues/42/labels/9"} => {204, %{}}
      }

      assert {:ok, :removed} =
               ForgeClient.remove_label("fleet/lcars", 42, "lcars-in-flight", opts(handlers))
    end

    test "close_issue : PATCH state closed" do
      handlers = %{
        {"PATCH", "/api/v1/repos/fleet/lcars/issues/42"} => {201, %{"state" => "closed"}}
      }

      assert {:ok, :closed} = ForgeClient.close_issue("fleet/lcars", 42, opts(handlers))
    end
  end
end
