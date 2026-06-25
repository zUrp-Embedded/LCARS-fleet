defmodule Fleet.MCP.BindAddressTest do
  @moduledoc """
  Contrat de bind du listener MCP pod-facing.

  Le transport HTTP ExMCP veut son option `:host` sous forme de STRING : il fait `to_string(host)`
  (Logger « Starting MCP HTTP server on <host>… ») AVANT son `parse_host`, donc lui passer un TUPLE IP
  crashe le listener au démarrage (`Protocol.UndefinedError String.Chars` pour Tuple → node down au boot).
  Le superviseur DOIT donc passer `host: "127.0.0.1"` (string) par défaut : loopback est COMPATIBLE avec
  les pods (ils joignent le MCP via le pont stdio→HTTP sur http://127.0.0.1:<port>/mcp — même hôte).
  Exposition publique = opt-in nommé (`LCARS_BIND_HOST`). Ce test fige l'option `:host` du child-spec
  PodTools ET prouve que ce host démarre RÉELLEMENT le listener (régression : un tuple ne démarrait pas).
  """
  use ExUnit.Case, async: false

  setup do
    on_exit(fn -> System.delete_env("LCARS_BIND_HOST") end)
    :ok
  end

  # pod_facing_children/1 ne matérialise un child que si :pod_facing_port est posé.
  # On le passe en opt direct (pas d'app-env global → pas de listener parasite).
  defp pod_facing_host(opts \\ []) do
    [child] = Fleet.MCP.Supervisor.pod_facing_children([pod_facing_port: 0] ++ opts)
    {Fleet.MCP.PodTools, :start_link, [start_opts]} = child.start
    Keyword.fetch!(start_opts, :host)
  end

  test "aucun port pod-facing → aucun listener (pas de bind)" do
    assert Fleet.MCP.Supervisor.pod_facing_children([]) == []
  end

  test "bind loopback par défaut (host = string \"127.0.0.1\", PAS un tuple)" do
    System.delete_env("LCARS_BIND_HOST")
    host = pod_facing_host()
    # STRING, pas tuple : ExMCP to_string le host au démarrage (un tuple crasherait le listener).
    assert host == "127.0.0.1"
    assert is_binary(host)
  end

  test "override global LCARS_BIND_HOST → host (string) threadé dans PodTools" do
    System.put_env("LCARS_BIND_HOST", "0.0.0.0")
    assert pod_facing_host() == "0.0.0.0"
  end

  test "le host du superviseur DÉMARRE réellement le listener ExMCP (régression : un tuple crashait)" do
    # Le contrat réel : ExMCP fait `to_string(host)` (Logger) AVANT `parse_host` → un host non-string
    # crashe `start_http_server` (`Protocol.UndefinedError String.Chars` pour Tuple) → `Fleet.MCP.PodTools`
    # ne démarre pas → app fleet_mcp down → NODE DOWN AU BOOT. Aucun test ne démarrait le listener avec le
    # host RÉEL du superviseur (les tests de bridge passaient un host par défaut string) → le crash passait
    # le gate hermétique et tombait au boot live. Ce test démarre le VRAI PodTools avec le host produit par
    # le superviseur. Régression prouvée : repasser `BindAddress.host_string` → `ip` (tuple) → ce `start_link`
    # échoue/raise.
    host = pod_facing_host()
    ref = :"bind_addr_real_#{System.unique_integer([:positive])}"

    assert {:ok, pid} =
             Fleet.MCP.PodTools.start_link(transport: :http, host: host, port: 0, ranch_ref: ref)

    assert is_pid(pid)
    GenServer.stop(pid)
  end
end
