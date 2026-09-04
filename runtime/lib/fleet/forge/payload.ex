defmodule Fleet.Forge.Payload do
  @moduledoc """
  La lecture des charges de la forge : UN chemin par fait, declare ici et nulle part ailleurs.

  `Fleet.Forge.Client` rend les reponses Gitea telles quelles — des maps JSON decodees. Sans ce
  module, chaque lecteur de `pilot`, `mcp`, `admiral` ou `application` indexe ces maps par clef
  string : la forme de l'API d'un tiers est connue hors du domaine, une montee de version de la
  forge se traite au `grep`, et rien ne repond a « de quels champs dependons-nous ».

  Ce module est le pendant, cote CHARGE, de ce que `Fleet.Forge.Protocol` fait cote CHAINES. Son
  invariant est le meme, exprime autrement : le chemin d'un champ est ecrit UNE fois, dans
  `@paths`, et tout lecteur en derive.

  ## Ce que la mesure a etabli, et qui change les lecteurs

  Capture reelle du 2026-09-02 (`test/fixtures/forge/`, `gitea/gitea:1.26.1-rootless`, digest
  verifie sur le conteneur) :

    * `assignee`, `milestone`, `pull_request`, `merged_at` valent `null` quand ils ne sont pas
      renseignes — un acces non garde casse. Tous les lecteurs d'ici rendent `nil`, jamais une
      exception ;
    * la specification OpenAPI de cette version ne declare **AUCUN** champ requis, pas meme
      `number`. Aucun lecteur ne peut donc s'appuyer sur la presence de quoi que ce soit ;
    * `repository.full_name` existe sur une ISSUE et pas sur une PR — l'asymetrie est reelle, elle
      n'est pas une erreur de capture ;
    * la meme forge rend DEUX HOTES differents selon l'endpoint (`127.0.0.1:23101` sur la PR,
      `gitea:3000` sur l'issue). C'est le motif pour lequel `html_url` n'est lu nulle part, adosse
      a une mesure et non a un raisonnement.

  ⚠ CE MODULE NE FABRIQUE PAS DE CHARGE, et c'est deliberе : la production n'en construit jamais.
  La co-location build/parse de `Protocol` n'a donc pas de sens litteral ici. Ce qui la remplace est
  mecanique : `forge/payload_test.exs` applique CHAQUE lecteur a la capture REELLE et exige une
  valeur. Un chemin qui derive ne se lit pas dans une relecture — il rougit.
  """

  @typedoc "Une charge decodee de la forge : une map a clefs string, rien de plus garanti."
  @type t :: map()

  # UN CHEMIN PAR FAIT. Ajouter un fait, c'est ajouter une ligne ici et son lecteur en dessous —
  # jamais une clef string ailleurs dans le depot.
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
  Les chemins declares, par fait.

  Existe pour que le temoin puisse les parcourir : une liste que seul un humain relit derive, une
  liste qu'un test parcourt ne peut pas.
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

  # `merged` absent sur une issue, `false` sur une PR ouverte : les deux se lisent « non fusionnee »,
  # et aucun appelant n'a besoin de les distinguer.
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

  # Les NOMS des labels. La charge rend des objets complets ; aucun appelant du depot n'a besoin
  # d'autre chose que du nom, et rendre l'objet reconduirait la fuite qu'on ferme.
  # Les objets BRUTS. Un seul usage legitime : les rendre a une fonction du domaine forge qui les
  # attend sous cette forme (`route_from_labels/1`). Partout ailleurs, `label_names/1`.
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

  # ⚠ PRESENT SUR UNE ISSUE, ABSENT D'UNE PR — mesure du 2026-09-02, pas une supposition.
  @doc false
  @spec repository_full_name(t()) :: String.t() | nil
  def repository_full_name(p), do: get(p, :repository_full_name)

  @doc false
  @spec full_name(t()) :: String.t() | nil
  def full_name(p), do: get(p, :full_name)

  @doc false
  @spec default_branch(t()) :: String.t() | nil
  def default_branch(p), do: get(p, :default_branch)

  # Gitea carries BOTH `assignees` (list) and `assignee` (single); the list wins when present.
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
