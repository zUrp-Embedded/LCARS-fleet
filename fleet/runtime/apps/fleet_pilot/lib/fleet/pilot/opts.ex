defmodule Fleet.Pilot.Opts do
  @moduledoc """
  Helpers purs de construction de keyword-lists d'options (opts/seams injectables).

  Source UNIQUE de l'idiome « pose la clé SI la valeur n'est pas nil » — utilisé par
  les builders d'opts du pilot (`StepRunConsumer`, `ForgeClient.Transport`, `Poller`)
  pour n'injecter un seam/paramètre optionnel que lorsqu'il est réellement présent.
  """

  @doc """
  Pose `{key, value}` dans `opts` SI `value != nil` ; sinon rend `opts` inchangé
  (la valeur par défaut avale l'absence). Préserve l'ordre existant (`Keyword.put`).
  """
  @spec maybe_put(keyword(), atom(), term()) :: keyword()
  def maybe_put(opts, _key, nil), do: opts
  def maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
