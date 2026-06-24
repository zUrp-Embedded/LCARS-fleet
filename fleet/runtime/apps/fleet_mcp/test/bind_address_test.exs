defmodule Fleet.MCP.BindAddressTest do
  @moduledoc """
  Contrat de bind du listener MCP pod-facing.

  Le transport HTTP ExMCP dérive son ip d'écoute de l'option `:host`
  (`ExMCP.Server.Transport.parse_host/1`, qui accepte un tuple IP tel quel). Le
  superviseur DOIT passer `host: {127,0,0,1}` par défaut : loopback est
  COMPATIBLE avec les pods (ils joignent le MCP via le pont stdio→HTTP sur
  http://127.0.0.1:<port>/mcp — même hôte). Exposition publique = opt-in nommé
  (`LCARS_BIND_HOST`). Ce test fige l'option `:host` du child-spec PodTools.
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

  test "bind loopback par défaut (host = {127,0,0,1})" do
    System.delete_env("LCARS_BIND_HOST")
    assert pod_facing_host() == {127, 0, 0, 1}
  end

  test "override global LCARS_BIND_HOST → host threadé dans PodTools" do
    System.put_env("LCARS_BIND_HOST", "0.0.0.0")
    assert pod_facing_host() == {0, 0, 0, 0}
  end
end
