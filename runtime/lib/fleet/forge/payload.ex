defmodule Fleet.Forge.Payload do
  @moduledoc """
  Chemins des faits lus dans les charges JSON de la forge, centralises dans @paths.
  get/2 rend nil si un chemin manque ou traverse une non-map, mais ne valide pas la valeur finale.
  Les predicats comparent a true ; les projections de listes ont leurs propres replis.

  Capture du 2026-09-02, test/fixtures/forge/ (gitea/gitea:1.26.1-rootless, digest documente) :
  champs optionnels null, repository.full_name present sur l'issue mais absent de la PR,
  et hotes d'URL differents (127.0.0.1:23101 / gitea:3000). Ce dernier constat motive
  l'absence de lecteur html_url ici. L'OpenAPI capturee ne declarait aucun champ requis.
  Les tests confrontent les chemins aux captures ; leur resolution seule ne valide pas le type
  ni le sens du champ choisi. La fabrique de charges reste dans le support de test.
  """

  @typedoc "Une charge decodee de la forge : une map a clefs string, rien de plus garanti."
  @type t :: map()

  # Ajouter un fait avec son lecteur et une capture qui couvre son chemin.
  @paths %{
    number: ["number"],
    state: ["state"],
    title: ["title"],
    body: ["body"],
    merged: ["merged"],
    mergeable: ["mergeable"],
    head_ref: ["head", "ref"],
    head_sha: ["head", "sha"],
    base_ref: ["base", "ref"],
    labels: ["labels"],
    label_names: ["labels"],
    assignee_login: ["assignee", "login"],
    author_login: ["user", "login"],
    repository_full_name: ["repository", "full_name"],
    full_name: ["full_name"],
    default_branch: ["default_branch"],
    draft: ["draft"],
    updated_at: ["updated_at"],
    created_at: ["created_at"],
    assignee_logins: ["assignees"]
  }

  @doc """
  Les chemins declares, parcourus par les tests et la fabrique de fixtures.
  """
  @spec paths() :: %{atom() => [String.t()]}
  def paths, do: @paths

  @doc false
  @spec get(t(), atom()) :: term() | nil
  def get(payload, fait) when is_map(payload) and is_map_key(@paths, fait) do
    Enum.reduce_while(Map.fetch!(@paths, fait), payload, fn clef, acc ->
      case acc do
        %{^clef => v} -> {:cont, v}
        _ -> {:halt, nil}
      end
    end)
  end

  def get(_payload, fait) when is_map_key(@paths, fait), do: nil

  @doc false
  @spec number(t()) :: integer() | nil
  def number(p), do: get(p, :number)

  @doc false
  @spec state(t()) :: String.t() | nil
  def state(p), do: get(p, :state)

  @doc false
  @spec title(t()) :: String.t() | nil
  def title(p), do: get(p, :title)

  @doc false
  @spec body(t()) :: String.t() | nil
  def body(p), do: get(p, :body)

  # Seul true vaut fusionne ; absence, false et valeurs hors-schema donnent false.
  @doc false
  @spec merged?(t()) :: boolean()
  def merged?(p), do: get(p, :merged) == true

  @doc false
  @spec mergeable(t()) :: boolean() | nil
  def mergeable(p), do: get(p, :mergeable)

  @doc false
  @spec head_ref(t()) :: String.t() | nil
  def head_ref(p), do: get(p, :head_ref)

  @doc false
  @spec head_sha(t()) :: String.t() | nil
  def head_sha(p), do: get(p, :head_sha)

  @doc false
  @spec base_ref(t()) :: String.t() | nil
  def base_ref(p), do: get(p, :base_ref)

  # Liste brute pour les fonctions forge telles route_from_labels/1 ; entrees non validees.
  @doc false
  @spec labels(t()) :: [map()]
  def labels(p) do
    case get(p, :labels) do
      l when is_list(l) -> l
      _ -> []
    end
  end

  @doc false
  @spec label_names(t()) :: [String.t()]
  def label_names(p) do
    case get(p, :label_names) do
      l when is_list(l) -> for %{"name" => n} <- l, is_binary(n), do: n
      _ -> []
    end
  end

  @doc false
  @spec assignee_login(t()) :: String.t() | nil
  def assignee_login(p), do: get(p, :assignee_login)

  @doc false
  @spec author_login(t()) :: String.t() | nil
  def author_login(p), do: get(p, :author_login)

  @doc false
  @spec repository_full_name(t()) :: String.t() | nil
  def repository_full_name(p), do: get(p, :repository_full_name)

  @doc false
  @spec full_name(t()) :: String.t() | nil
  def full_name(p), do: get(p, :full_name)

  @doc false
  @spec default_branch(t()) :: String.t() | nil
  def default_branch(p), do: get(p, :default_branch)

  # Reads assignees only, with no fallback to the singular assignee field.
  @doc false
  @spec assignee_logins(t()) :: [String.t()]
  def assignee_logins(p) do
    case get(p, :assignee_logins) do
      l when is_list(l) -> for %{"login" => n} <- l, is_binary(n), do: n
      _ -> []
    end
  end

  @doc false
  @spec draft?(t()) :: boolean()
  def draft?(p), do: get(p, :draft) == true

  @doc false
  @spec updated_at(t()) :: String.t() | nil
  def updated_at(p), do: get(p, :updated_at)

  @doc false
  @spec created_at(t()) :: String.t() | nil
  def created_at(p), do: get(p, :created_at)
end
