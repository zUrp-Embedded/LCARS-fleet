defmodule Fleet.Forge.Client.CI do
  @moduledoc """
  Réduit l'historique des statuts par contexte pour Fleet.Forge.Client. Fonctions publiques
  internes au domaine, hors couture forge(). Le plus grand id entier représente le statut
  courant ; si tous les ids ne sont pas entiers, le verdict garde le pire et le diagnostic
  rouge omet ce contexte. Les doublons d'id ne sont pas départagés : première occurrence gagnante.
  """

  @typedoc """
  Contexte en échec. description/target_url non binaires ou entièrement blancs deviennent nil ;
  les autres chaînes sont conservées sans validation de l'URL ni masquage.
  """
  @type red :: %{
          context: String.t(),
          description: String.t() | nil,
          target_url: String.t() | nil
        }

  @doc false
  # Les contextes CI en echec, avec leur URL — un par contexte, le plus recent.
  @spec red_contexts([map()]) :: [red()]
  def red_contexts(statuses) do
    statuses
    |> Enum.group_by(& &1["context"])
    |> Enum.flat_map(&latest_if_red/1)
    |> Enum.sort_by(& &1.context)
  end

  # Ne nommer que le rouge au max id d'un groupe entièrement ordonnable, avec contexte binaire.
  defp latest_if_red({context, group}) when is_binary(context) do
    if Enum.all?(group, &is_integer(&1["id"])) do
      latest = Enum.max_by(group, & &1["id"])
      if latest["status"] in ~w(failure error), do: [red_context(context, latest)], else: []
    else
      []
    end
  end

  defp latest_if_red(_group), do: []

  @doc false
  # Construit une map sans vérifier que l'entrée porte effectivement un état rouge.
  @spec red_context(String.t(), map()) :: red()
  def red_context(context, entry) do
    %{
      context: context,
      description: presence(entry["description"]),
      target_url: presence(entry["target_url"])
    }
  end

  @doc false
  # Une chaine non vide, ou `nil` — une chaine blanche n'est pas une valeur.
  @spec presence(term()) :: String.t() | nil
  def presence(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  def presence(_), do: nil

  # Gitea 1.26.1, mesures 2026-08-08 et 2026-09-02 (captures test/fixtures/forge/) : ordre
  # par défaut ancien d'abord ; sort=leastindex observé récent d'abord. Prendre le max id
  # plutôt que dépendre de cet ordre. Le champ élémentaire est status, pas l'agrégat state.

  @doc false
  # Renvoie des valeurs status (malgré le spec historique map), pas les objets de réponse.
  @spec current_per_context([map()]) :: [map()]
  def current_per_context(statuses) do
    statuses
    |> Enum.group_by(& &1["context"])
    |> Enum.flat_map(fn {_context, group} ->
      if Enum.all?(group, &is_integer(&1["id"])) do
        [group |> Enum.max_by(& &1["id"]) |> Map.get("status")]
      else
        # Ordre indéterminable : garder tous les états pour ne pas masquer un rouge.
        Enum.map(group, & &1["status"])
      end
    end)
  end

  @doc false
  # Réduit des valeurs status ; le spec map historique ne décrit pas les entrées effectivement lues.
  @spec worst_ci_state([map()] | []) :: atom()
  def worst_ci_state([]), do: :none

  # Politique : skipped ne vote pas (tout skipped → none), warning vaut success. Un état
  # inconnu reste pending pour ne pas autoriser le merge ; la cause d'un skipped n'est pas vérifiée.
  def worst_ci_state(states) do
    voting = Enum.reject(states, &(&1 == "skipped"))

    cond do
      voting == [] -> :none
      Enum.any?(voting, &(&1 in ["failure", "error"])) -> :failure
      Enum.any?(voting, &(&1 == "pending")) -> :pending
      Enum.all?(voting, &(&1 in ["success", "warning"])) -> :success
      true -> :pending
    end
  end
end
