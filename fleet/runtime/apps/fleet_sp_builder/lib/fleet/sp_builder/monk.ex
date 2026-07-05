defmodule Fleet.SPBuilder.Monk do
  @moduledoc """
  Résolution de l'injection monk — extrait de `Fleet.SPBuilder` (source de donnée
  distincte : un registry YAML, seule I/O non-markdown du composeur).

  Si le cap-profile porte `spec.knowledge.{monk_registry, monk_instance}`, le module
  lit le registry YAML (registry mémoire, shape `spec.monks`), trouve l'entrée
  `monk_instance` et rend `%{persona_hint, corpus_paths}`. L'injection est purement
  ADDITIVE : pour un non-monk, le flux `compose/3` reste byte-identique (aucune
  branche ne le traverse) — c'est le contrat de `resolve_or_empty/2`.

  Fonctions **pures** (lecture FS only, aucun process). L'API publique du composeur
  reste `Fleet.SPBuilder.resolve_monk_injection/2` (defdelegate vers `resolve/2`).
  """

  @type injection :: %{persona_hint: String.t(), corpus_paths: [String.t()]}

  @doc """
  Résout l'injection monk du cap-profile.

    * `{:ok, %{persona_hint, corpus_paths}}` — cap-profile monk, entrée trouvée.
    * `:not_a_monk` — pas de `monk_registry`/`monk_instance` dans `spec.knowledge`.
    * `{:error, {:registry_unreadable, path, reason}}` — YAML illisible.
    * `{:error, {:not_a_memory_registry, path}}` — YAML sans `spec.monks` (liste).
    * `{:error, {:monk_instance_not_found, instance}}` — instance absente du registry.

  ## opts

    * `:monk_registry_root` — racine résolvant le path relatif du registry
      (test-seam ; défaut config `:fleet_sp_builder, :monk_registry_root`
      puis `Application.app_dir(:fleet_cap_profile, "priv/canon/cap-profiles/monks")`).

  Le champ `monk_registry` dans le cap-profile = basename (ex `alpha.yaml`)
  — le code le résout via `:monk_registry_root`. Ce n'est PAS un path absolu :
  le registry vit in-repo sous la racine, jamais un chemin doctrine externe.
  """
  @spec resolve(Fleet.CapProfile.t(), keyword()) ::
          {:ok, injection()} | :not_a_monk | {:error, term()}
  def resolve(%Fleet.CapProfile{spec: spec}, opts \\ []) do
    knowledge = Map.get(spec, "knowledge", %{})
    registry_rel = Map.get(knowledge, "monk_registry")
    instance = Map.get(knowledge, "monk_instance")

    cond do
      is_nil(registry_rel) or is_nil(instance) ->
        :not_a_monk

      true ->
        root =
          Keyword.get(opts, :monk_registry_root) ||
            Application.get_env(:fleet_sp_builder, :monk_registry_root) ||
            Application.app_dir(:fleet_cap_profile, "priv/canon/cap-profiles/monks")

        path = Path.join(root, registry_rel)

        with {:ok, reg} <- read_registry(path),
             {:ok, monk} <- find_monk(reg, instance) do
          {:ok,
           %{
             persona_hint: Map.get(monk, "persona_hint", ""),
             corpus_paths: Map.get(monk, "corpus_paths", [])
           }}
        end
    end
  end

  @doc """
  Variante pour le flux `compose/3` : `:not_a_monk` → injection VIDE
  (`persona_hint: ""`, `corpus_paths: []`) pour que le flux reste byte-identique
  pour un non-monk ; `{:error, _}` → propagé (fail-loud).
  """
  @spec resolve_or_empty(Fleet.CapProfile.t(), keyword()) ::
          {:ok, injection()} | {:error, term()}
  def resolve_or_empty(cap_profile, opts) do
    case resolve(cap_profile, opts) do
      {:ok, inj} -> {:ok, inj}
      :not_a_monk -> {:ok, %{persona_hint: "", corpus_paths: []}}
      {:error, _} = err -> err
    end
  end

  @doc """
  Section markdown « Monk persona » à concaténer aux fragments modop du SP :
  vide si `persona_hint` est vide (non-monk → aucun octet ajouté au SP).
  """
  @spec persona_section(injection()) :: String.t()
  def persona_section(%{persona_hint: ""}), do: ""

  def persona_section(%{persona_hint: ph}) when is_binary(ph),
    do: "\n\n## Monk persona\n\n" <> ph

  defp read_registry(path) do
    # Pas d'attribut `kind` (un seul kind par dossier `monks/*.yaml`, le path
    # déclare le rôle). Validation = présence de `spec.monks` au shape attendu
    # (liste), pas un `kind` embarqué dans le YAML.
    case YamlElixir.read_from_file(path) do
      {:ok, %{"spec" => %{"monks" => monks}} = reg} when is_list(monks) ->
        {:ok, reg}

      {:ok, _} ->
        {:error, {:not_a_memory_registry, path}}

      {:error, reason} ->
        {:error, {:registry_unreadable, path, reason}}
    end
  end

  defp find_monk(reg, instance) do
    monks = get_in(reg, ["spec", "monks"]) || []

    case Enum.find(monks, &(Map.get(&1, "name") == instance)) do
      nil -> {:error, {:monk_instance_not_found, instance}}
      monk -> {:ok, monk}
    end
  end
end
