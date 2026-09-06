defmodule Fleet.Application.CatalogueDeposits do
  @moduledoc """
  Which catalogues this forge carries as DEPOSITS — the `available` half of the lifecycle.

  ## The model

  A catalogue arrives the way a project does: its author pushes it from their own disk into their
  own space on the forge (`<user>/<repo>`). That push is an EXTERNAL user action — LCARS is not its
  author and has nothing to offer it. What LCARS does is read the forge and say what it sees.

  Any user may deposit. Only an admin may install. That asymmetry is the whole access model, and it
  needs no flag anywhere: depositing is a git push, installing is a command.

  ## What makes a repo a candidate

  It carries `catalogue.yaml` at its root. The manifest's `name:` is the catalogue's identity — not
  the repo name, not the owner. A user may call their repo anything; the manifest says what it IS.

  ## What makes a repo a STORE, and why it is not a name

  The store is the copy WE pushed into an installed catalogue's own org. Listing it as a deposit
  would report every installed catalogue as also available from itself.

  Recognising it by NAME — any repo called `catalogue`, whoever owns it — would reserve the most
  natural repo name in every user's namespace, and would do it in SILENCE: a user calling their
  deposit `catalogue` gets dropped with no log, no line, no refusal.

  The discriminant is `owner == manifest.name`, and it is true BY CONSTRUCTION: the org is created
  from the manifest (`/orgs/${name}/repos`).

  What makes it not a rarity bet — the part a prefix could never buy — is that Gitea gives users and
  organisations ONE namespace. A catalogue named `X` requires the org `X`, so no user account can be
  called `X`, so a repo in a user's space can never satisfy `owner == name`. A prefix protects by
  rarity, and a rarity bet is lost exactly once. This protects by impossibility.

  Cost: the filter runs AFTER the manifest is read, so a store costs one manifest read per listing.
  That is per installed catalogue, not per repo — and it buys back the whole `catalogue` name.

  ## Two deposits of the same name: we REFUSE, and we name both

  ⚖ user. We do not guess which one is the real one — not the first, not the newest,
  not the biggest. Each of those is a choice we could not justify to whoever loses. The list refuses
  and names both owners; the humans sort it out by deleting one.

  A refusal that names one owner would be worse than useless: it would look like an answer.

  ## A private deposit costs no code

  `/repos/search` returns only what the token can SEE, so a private repo is simply not there
  (measured — cf. `Fleet.Forge.Client.Repo.search_repos/1`). ⚖ user: *"if the user left their repo
  private and we don't see it, well, we don't see it. We are not here to write a git tutorial."*
  The absence from the list IS the message; there is nothing to detect and nothing to explain.
  """

  alias Fleet.Forge.Payload

  require Logger

  @manifest Fleet.Catalogue.manifest_file()

  @typedoc """
  A deposit the forge carries: the catalogue's declared name, where it sits, and the head sha of
  its default branch — the value that later answers "has this moved since it was installed".
  """
  @type deposit :: %{
          name: String.t(),
          repo: String.t(),
          owner: String.t(),
          branch: String.t(),
          sha: String.t()
        }

  @doc """
  Every deposit the forge carries, by declared name.

  Returns `{:ok, %{name => deposit}}`, or `{:error, {:duplicate_catalogues, [{name, [repo]}]}}`
  when two repos declare the same name. A forge read failure propagates: an unreadable forge says
  NOTHING about what exists, and inferring an empty list from it would report every installed
  catalogue as vanished.
  """
  @spec list(keyword()) :: {:ok, %{String.t() => deposit()}} | {:error, term()}
  def list(opts \\ []) do
    repo_mod = Keyword.get(opts, :forge_repo, Fleet.Forge.Client.Repo)

    with {:ok, repos} <- repo_mod.search_repos(opts), do: from_repos(repos, opts)
  end

  @doc """
  Same reading, on a repo list ALREADY fetched — deposits only.
  """
  @spec from_repos([map()], keyword()) :: {:ok, %{String.t() => deposit()}} | {:error, term()}
  def from_repos(repos, opts \\ []) when is_list(repos) do
    with {:ok, deposits, _stores} <- split(repos, opts), do: {:ok, deposits}
  end

  @doc """
  BOTH halves of the lifecycle from ONE list of repos: `{:ok, deposits, stores}`.

  `deposits` is keyed by declared name; `stores` maps a catalogue name to the raw repo map of the
  store that carries it (`owner == name`, unverified as to whether that owner is an org — that
  question belongs to whoever signs an installation, cf. `CatalogueLifecycle`).

  ## Why the two halves are read TOGETHER and not twice

  It costs ONE `/repos/search` and ONE manifest read per repo. Reading twice would not only cost
  round trips: the two reads could straddle a push and produce a state nobody ever had — and worse,
  the two halves would then answer "is this a store?" independently. A discriminant applied by two
  readers is a discriminant that drifts; here there is a single classification and the halves cannot
  disagree, because they are the two outputs of one decision.
  """
  @spec split([map()], keyword()) ::
          {:ok, %{String.t() => deposit()}, %{String.t() => map()}} | {:error, term()}
  def split(repos, opts \\ []) when is_list(repos) do
    repo_mod = Keyword.get(opts, :forge_repo, Fleet.Forge.Client.Repo)
    files_mod = Keyword.get(opts, :forge_files, Fleet.Forge.Client.Files)

    classified =
      repos
      |> Enum.reject(&empty?/1)
      |> Enum.flat_map(&classify(&1, repo_mod, files_mod, opts))

    stores = pick_stores(for {:store, name, repo} <- classified, do: {name, repo})

    with {:ok, deposits} <- group(for {:deposit, d} <- classified, do: d) do
      {:ok, deposits, stores}
    end
  end

  # ⚠ UN `into: %{}` GARDERAIT LE DERNIER VU, EN SILENCE. Deux depots d'une meme org peuvent tous
  # deux declarer le nom de cette org — un magasin et sa copie oubliee, par exemple — et le magasin
  # effectif serait alors celui que l'ordre de `/repos/search` designe.
  #
  # ON NE REFUSE PAS LA LISTE, contrairement au doublon de DEPOTS, et l'asymetrie est voulue : un
  # doublon de depots est une question sans reponse (« lequel installer ? ») ; ici le catalogue EST
  # installe, et refuser le ferait disparaitre de la liste — un catalogue vivant efface parce qu'il
  # a un depot de trop. On choisit donc, mais de facon DETERMINISTE (le premier par nom de depot,
  # trie) et en le DISANT : deux conteneurs lisant la meme forge doivent voir le meme magasin.
  defp pick_stores(pairs) do
    pairs
    |> Enum.group_by(fn {name, _repo} -> name end, fn {_name, repo} -> repo end)
    |> Map.new(fn
      {name, [one]} ->
        {name, one}

      {name, many} ->
        [chosen | _] = sorted = Enum.sort_by(many, &Payload.full_name/1)

        Logger.warning(
          "CatalogueDeposits: #{length(many)} repos claim to be the store of '#{name}' " <>
            "(#{Enum.map_join(sorted, ", ", &Payload.full_name/1)}). Following " <>
            "#{Payload.full_name(chosen)} — first by name, so every container reading this forge follows the " <>
            "same one. Delete the others: only one of them is what `catalogue install` pushes to."
        )

        {name, chosen}
    end)
  end

  # An empty repo carries no manifest to read, and asking for one costs a round trip to learn what
  # the listing already said.
  defp empty?(%{"empty" => true}), do: true
  defp empty?(_), do: false

  # Returns a one-element list or none — `flat_map` so that a repo we cannot read drops out with a
  # named warning instead of failing the whole listing. A single unreadable repo among fifty must
  # not hide the other forty-nine.
  defp classify(repo, repo_mod, files_mod, opts) when is_map(repo) do
    case Payload.full_name(repo) do
      full when is_binary(full) -> do_classify(repo, full, repo_mod, files_mod, opts)
      _ -> []
    end
  end

  defp classify(_repo, _repo_mod, _files_mod, _opts), do: []

  defp do_classify(repo, full, repo_mod, files_mod, opts) do
    branch = Payload.default_branch(repo) || "main"

    with {:ok, %{content: yaml}} <-
           files_mod.get_file(full, @manifest, Keyword.put(opts, :ref, branch)),
         {:ok, name} <- manifest_name(yaml) do
      identify(name, repo, full, branch, repo_mod, opts)
    else
      # Not a catalogue. The overwhelmingly common case, and silent by design: every project repo
      # on the forge takes this branch on every listing.
      {:error, :not_found} ->
        []

      # ⚠ LE MANIFESTE A ETE LU. Ce n'est pas une panne de forge, c'est un YAML dont le `name:` n'est
      # pas en colonne zero — donc un geste d'AUTEUR, pas d'operateur. Les confondre envoie celui qui
      # lit le log chercher un probleme reseau devant un fichier qu'il pouvait corriger.
      {:error, :no_name_in_manifest} ->
        Logger.warning(
          "CatalogueDeposits: #{full} carries a #{@manifest} with no `name:` at COLUMN ZERO — NOT " <>
            "listed. In YAML an indented `name:` belongs to the key above it, so a `name:` under " <>
            "`roles:` declares a role, not the catalogue. Its owner sees nothing; this line is the " <>
            "only trace."
        )

        []

      {:error, reason} ->
        unreadable(full, reason)
    end
  end

  # ⚠ LE STORE SE RECONNAIT ICI, ET NULLE PART AILLEURS. C'est le seul point du code ou l'identite
  # declaree et le proprietaire sont tous les deux connus, donc le seul ou la question puisse etre
  # posee. La poser une seconde fois ailleurs (sur le NOM du depot, par exemple) donne deux
  # reponses qui divergent le jour ou une seule est corrigee.
  #
  # Un store ne coute PAS de `branch_head` : l'identite tranche avant. La tete d'un store est lue
  # plus tard, et seulement par l'appelant qui la compare.
  defp identify(name, repo, full, branch, repo_mod, opts) do
    # Exclure un store est le fonctionnement normal, pas une erreur : SILENCIEUX. Une ligne par
    # catalogue installe a chaque listage serait du bruit qui apprend a l'operateur a sauter le log.
    cond do
      owner_of(full) == name and org_owner?(name, repo_mod, opts) ->
        [{:store, name, repo}]

      # ⚠ LE NOM DU CATALOGUE LIVRE NE PEUT PAS ETRE UNE CANDIDATURE, et un depot le porte : la
      # fleet publie sa propre reference sur la forge, pour qu'elle
      # soit LISIBLE et FORKABLE. Sans cette clause, ce depot serait un candidat de plus nomme
      # `fleet` — et le premier fork qui garde son manifeste tel quel en ferait DEUX, donc
      # `{:duplicate_catalogues, ...}`, donc `catalogue list` refusant la liste ENTIERE pour tout le
      # monde. Un objet publie pour etre forke ne doit pas casser le conteneur au premier fork.
      #
      # Ce n'est pas un cas particulier concede : ce nom ne peut structurellement pas etre installe
      # depuis la forge (`CatalogueLifecycle.eval_source/1` rend BUNDLED), donc un depot qui le
      # revendique n'est candidat a rien. Et c'est DIT — une candidature ecartee en silence est le
      # defaut que ce module vient de fermer un cran plus haut.
      name == Fleet.Catalogue.bundled_name() ->
        Logger.info(
          "CatalogueDeposits: #{full} declares '#{name}', the catalogue carried by the release. It " <>
            "is installed by construction, so no deposit can be installed under that name — this " <>
            "repo is here to be READ and FORKED. A fork meant to be installed changes `name:` in " <>
            "its #{@manifest}."
        )

        []

      true ->
        case repo_mod.branch_head(full, branch, opts) do
          {:ok, sha} ->
            [
              {:deposit,
               %{name: name, repo: full, owner: owner_of(full), branch: branch, sha: sha}}
            ]

          {:error, reason} ->
            unreadable(full, reason)
        end
    end
  end

  # ⚠ LES DEUX CONDITIONS SONT NECESSAIRES, ET AUCUNE NE RECOUVRE L'AUTRE.
  #
  #   `owner == manifest.name`  — ce depot est le magasin DE CE catalogue-la, pas un depot quelconque
  #                               pose dans une org quelconque.
  #   le proprietaire est une ORG — un compte perso `bob` dont le manifeste dit `name: bob` satisfait
  #                               la premiere et ment : le catalogue `bob` ne peut PAS etre installe
  #                               sur une forge ou `bob` est un humain, son org entrerait en collision
  #                               avec le compte.
  #
  # ⚠ ET C'EST POURQUOI LE TEST VIT ICI, PAS EN AVAL. Place plus loin, `split/2` rend des CANDIDATS
  # qu'un second lecteur recale — et un candidat recale TOMBE DANS UN TROU : ni magasin (pas une
  # org), ni depot (deja classe magasin), aucun log, aucune ligne. Un depot personnel declarant
  # `name: <son propre compte>` disparait alors de `catalogue list` SANS UN MOT, ce qui est mot pour
  # mot le defaut que ce module ferme un cran plus haut, avec une geometrie differente.
  #
  # La classification est donc COMPLETE ici, et le recale RETOMBE en depot — ce qu'il est. Il ne
  # s'installera jamais (son org entrerait en collision avec un compte), et ce refus-la appartient a
  # `catalogue install`, au moment ou un admin le demande : un refus a un moment reel vaut mieux
  # qu'une disparition a un moment invisible.
  #
  # L'objet `owner` de `/repos/search` ne porte AUCUN champ discriminant (mesure sur Gitea 1.26.1 :
  # memes cles pour une org et un compte). La question se pose donc a `/orgs/<owner>`.
  #
  # `{:error, _}` n'est PAS « pas une org » : une forge qui tousse sur le type ne retrograde pas un
  # catalogue installe en disponible. Le cout accepte : pendant la panne, un depot perso frais serait
  # annonce installe ; c'est transitoire et non pilotable par l'auteur du depot, la ou l'autre sens
  # retrograderait la flotte sur un hoquet.
  defp org_owner?(owner, repo_mod, opts) do
    case repo_mod.org_exists?(owner, opts) do
      {:ok, is_org} ->
        is_org

      {:error, reason} ->
        Logger.warning(
          "CatalogueDeposits: cannot read the owner type of #{owner} (#{inspect(reason)}) — " <>
            "counted as a store. An unreadable forge is not an answer, and the other reading would " <>
            "retrograde an installed catalogue on a hiccup."
        )

        true
    end
  end

  defp unreadable(full, reason) do
    Logger.warning(
      "CatalogueDeposits: #{full} carries a #{@manifest} that could not be read " <>
        "(#{inspect(reason)}) — NOT listed. Its owner sees nothing; this line is the only trace."
    )

    []
  end

  defp owner_of(full_name), do: full_name |> String.split("/", parts: 2) |> hd()

  # LA REGLE DU MANIFESTE VIT DANS `Fleet.Catalogue`, la fondation, et pas en copie ici : la porte
  # explicite (`Onboard.refute_store/2`) a besoin de la meme, et sa frontiere ne peut pas referencer
  # celle-ci. ELARGIR UNE FRONTIERE POUR AVOIR RAISON N'EST JAMAIS LE GESTE — la regle descend la ou
  # les deux peuvent la lire.
  defp manifest_name(yaml), do: Fleet.Catalogue.manifest_name(yaml)

  defp group(deposits) do
    by_name = Enum.group_by(deposits, & &1.name)

    case Enum.filter(by_name, fn {_name, list} -> length(list) > 1 end) do
      [] ->
        {:ok, Map.new(by_name, fn {name, [one]} -> {name, one} end)}

      dups ->
        {:error,
         {:duplicate_catalogues,
          Enum.map(dups, fn {name, l} -> {name, Enum.map(l, & &1.repo)} end)}}
    end
  end
end
