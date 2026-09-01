defmodule Mix.Tasks.Lcars.Contracts.Check.Catalogue do
  # Z4 — classe dans la boundary de son sujet, comme la tache qui l'utilise.
  use Boundary, classify_to: Fleet.Application

  @moduledoc """
  La lecture du catalogue de roles — l'artefact que plusieurs familles de murs interrogent.

  Le catalogue est la source des roles : leur nom, leur identite forge, leur place dans le
  deploiement. Deux familles le lisent pour des raisons differentes — celle qui verifie que les
  listes de provisionnement s'accordent, celle qui verifie que la surface d'outils est accordee aux
  bons roles. Elles partagent donc le LECTEUR, jamais le contrat.

  ⚠ LES DEUX ARBRES, TOUJOURS. Les listes de provisionnement couvrent le deploiement entier — un
  role de mecanisme a besoin de son compte forge autant qu'un producteur — et ne lire que l'arbre
  metier declarerait « en trop » les roles systeme dans chaque liste, rendant rouge un deploiement
  correct.
  """

  @doc false
  @spec scan_catalogue_roles(String.t()) :: [map()]
  def scan_catalogue_roles(root) do
    # BOTH catalogues. The provisioning lists cover the whole deployment — a mechanism role needs
    # its forge account exactly as much as a producer does — so scanning the business tree alone
    # would declare four roles "extra" in every list and turn a correct deployment red.
    [
      "priv/catalogue/cap_profile/canon/cap-profiles/*.yaml",
      "priv/catalogue-system/cap_profile/canon/cap-profiles/*.yaml"
    ]
    |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))
    |> Enum.reject(&String.starts_with?(Path.basename(&1), "_"))
    |> Enum.flat_map(fn path ->
      case YamlElixir.read_from_file(path) do
        {:ok, %{} = raw} ->
          [
            %{
              name: get_in(raw, ["metadata", "name"]) || Path.basename(path, ".yaml"),
              kind: Map.get(raw, "kind"),
              forge_identity: get_in(raw, ["metadata", "forge_identity"]) != false,
              role_index: get_in(raw, ["metadata", "role_index"]),
              capabilities: get_in(raw, ["spec", "capabilities"]) || [],
              allowed_tools: get_in(raw, ["spec", "scope", "allowedTools"]) || [],
              modop_default: get_in(raw, ["spec", "modop_set", "default"]) || [],
              modop_incompatible: get_in(raw, ["spec", "modop_set", "incompatible"]) || []
            }
          ]

        _ ->
          []
      end
    end)
  end
end
