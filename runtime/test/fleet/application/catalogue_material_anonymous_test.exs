defmodule Fleet.Application.CatalogueMaterialAnonymousTest do
  @moduledoc """
  La lecture du magasin est ANONYME face au compte AMBIANT de la config forge.

  Une release porte toujours `:pilot_forge` avec `account:` (le compte systeme, lu dans les faits).
  Resolu par le rail d'autorite, qui ne sert que les humains de la flotte, il refusait la porte
  outil lancee en `nobody` (`:not_a_worker`) : le magasin public n'etait jamais lu (banc 2001,
  2026-09-24). Ces temoins resolvent la config que `mesure` transmet au client, avec le vrai
  resolveur — `async: false`, parce que `:pilot_forge` est l'environnement global de l'app.
  """
  use ExUnit.Case, async: false

  alias Fleet.Application.CatalogueMaterial
  alias Fleet.Forge.Client.Transport

  defmodule CaptureRepo do
    @moduledoc false
    def list_branches(_repo, opts) do
      send(self(), {:config, Transport.resolve_config(opts)})
      {:ok, []}
    end
  end

  setup do
    previous = Application.get_env(:lcars_fleet, :pilot_forge)

    Application.put_env(:lcars_fleet, :pilot_forge,
      base_url: "http://forge.test",
      account: "system_starfleet"
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lcars_fleet, :pilot_forge, previous),
        else: Application.delete_env(:lcars_fleet, :pilot_forge)
    end)
  end

  defp mesure(opts) do
    CatalogueMaterial.mesure([forge_repo: CaptureRepo, store_repo: "lcars/_catalogues"] ++ opts)
  end

  test "un compte AMBIANT ne s'applique pas : le magasin se lit sans jeton" do
    assert {:ok, []} = mesure([])
    assert_received {:config, {:ok, %{anonymous: true, token: ""}}}
  end

  test "un jeton NOMME par l'appelant est garde : l'anonymat ne degrade rien" do
    assert {:ok, []} = mesure(token: "tok-appelant")
    assert_received {:config, {:ok, %{anonymous: false, token: "tok-appelant"}}}
  end
end
