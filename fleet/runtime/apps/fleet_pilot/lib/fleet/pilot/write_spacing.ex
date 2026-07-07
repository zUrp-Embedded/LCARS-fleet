defmodule Fleet.Pilot.WriteSpacing do
  @moduledoc """
  Gap anti-tie ENTRE deux écritures forge dont l'ORDRE d'affichage compte (dashboard/activité Gitea).
  Gitea horodate les events à la SECONDE : deux écritures dans la même seconde tiennent une égalité de
  `created_at` que le feed rend dans un ordre ARBITRAIRE (« logiquement avant, affiché après » —
  constaté en direct, plusieurs fois, sur des séquences DIFFÉRENTES).

  UN SEUL primitif, deux consommateurs : `StepRunCompleter` (comment de verdict → route/stage ; sceau
  de merge → unlock) et `ProjectOnboard` (create_repo → push main → push work/ops — la séquence tourne
  en local, quasi-instantanée, donc collision quasi garantie sans gap). Même config, même seam test —
  le concept est « écriture forge visible humain », pas « step_run » ni « onboard » spécifiquement.
  """

  @doc """
  Insère le gap configuré (`:fleet_pilot, :forge_write_spacing_ms`, défaut 2000ms ; 0 en test → no-op,
  cf. `config/test.exs`). Seam `:sleeper` dans `opts` (test — capture la durée demandée, ne dort pas
  réellement). NB : bloque brièvement l'appelant (assumé : déjà sur le chemin d'écritures HTTP
  synchrones — 2s achète une chronologie honnête, décision user).
  """
  @spec gap(keyword()) :: :ok
  def gap(opts \\ []) do
    case Application.get_env(:fleet_pilot, :forge_write_spacing_ms, 2000) do
      ms when is_integer(ms) and ms > 0 -> (opts[:sleeper] || (&Process.sleep/1)).(ms)
      _ -> :ok
    end

    :ok
  end
end
