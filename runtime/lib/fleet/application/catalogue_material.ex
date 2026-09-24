defmodule Fleet.Application.CatalogueMaterial do
  @moduledoc """
  Measures what the forge INSTALLS, for the converger that lays the local material.

  ⚠ THIS IS NOT `CatalogueStores`, AND THE DIFFERENCE IS THE ONE THAT MATTERS. That module answers
  `lcars catalogue list`, where prudence buys an honest listing: an absent store repository is
  `{:ok, %{}}`, because a forge carrying no installed catalogue is not a forge in error. Here the
  reader ERASES on what it is told — `forge.d/catalogues.sh` removes the material of a catalogue the
  forge no longer installs — so "the store is absent" and "the store installs nothing" MUST NOT
  collapse into one answer. Gitea returns the same 404 for four different facts: the repository was
  never created, it is private and this reads anonymously, the system org was renamed, or someone
  deleted it. One of those four means "nothing is installed"; the other three justify erasing
  nothing. `{:absent, repo}` is therefore its own answer, and the converger decides.

  ## What signs a branch

  One branch per catalogue, and a branch is the store of `x` only when BOTH hold:

    * its `#{Fleet.Catalogue.manifest_file()}` read AT THAT BRANCH declares `name: x` at COLUMN
      ZERO. In YAML an indented `name:` belongs to the key above it, so a `name:` under `roles:`
      declares a role — accepting it would let the first nested name steal the catalogue's
      identity. A branch with no manifest is not a catalogue (the store's own default branch
      carries a README), and says nothing;
    * the catalogue's ORG exists. A source without its role accounts is an interrupted install, and
      its projects would have nowhere to be born.

  A read that does not conclude — the manifest unreadable, the org's existence unknown — is a HOLD,
  never a refusal: its material is left exactly as it is.

  The catalogue the release carries is excluded. Its store lives on the forge like any other, but
  its material IS the release, and `Fleet.Catalogue` ignores an installed directory of that name:
  cloning it would lay a dead tree.

  ## What this does NOT do

  It lays nothing, clones nothing, erases nothing. The measure is the release's; the convergence
  and the verdict belong to the caller's protocol, and both rails map the same findings to their
  own dialect.

  **Last revised**: 2026-09-19
  """

  alias Fleet.Catalogue
  alias Fleet.Forge.Client.Files
  alias Fleet.Forge.Client.Repo, as: ForgeRepo

  require Logger

  @manifest Catalogue.manifest_file()

  @typedoc """
  What one branch signs.

  `:ok` carries the clone address, `:hold` the half of the reading that did not conclude
  (`"manifeste"` or `"proprietaire"`), `:warn` a branch that answered and is NOT a store — the
  sentence an operator needs to understand why their catalogue is not installed.
  """
  @type signature :: %{gravite: :ok | :hold | :warn, nom: String.t(), arg: String.t()}

  @doc """
  Reads the store repository and signs its branches.

    * `{:ok, signatures}` — the listing was read WHOLE. An empty list is a measure: the store
      exists and installs nothing.
    * `{:absent, repo}` — the store repository answered 404. Says nothing about what is installed.
    * `{:error, reason}` — the listing could not be read. No partial list is ever returned as
      `:ok`: a page that fails aborts the whole read, because a short list taken for a complete
      one would make the converger erase the material of every catalogue past the boundary.

  ⚠ THE LIMIT OF THAT GUARANTEE, and it belongs here because the erasure hangs on it: it covers
  pages that FAIL, not a forge that ends the listing early. `Transport.paginate/4` stops on an
  empty page even when the server announces more, and trusts `X-Total-Count` — so a store that
  answers an empty page mid-listing is indistinguishable from a complete one, and its catalogues
  past that point read as uninstalled.

  MEASURED 2026-09-20, against a disposable Gitea carrying 121 branches, queried exactly as
  `paginate/4` queries (`?page=N&limit=50`): pages of 50, 50, 21, then 0 — a correct, stable
  `X-Total-Count` of 121 throughout. Gitea FILLS its pages until exhaustion and only empties AFTER
  the end, so pagination stops on `121 >= 121` and the empty page is never fetched. The truncating
  shape is not reachable from this forge by a plain listing: it would take a mass branch deletion
  DURING the walk, on a store already holding more than fifty catalogues — below that there is one
  page and no second request. `test/fleet/forge/client/pagination_truncation_test.exs` pins both
  halves. No guard is warranted here; the day the transport is reworked, a snapshot ref in the
  request is the place to close it.

  Reading is ANONYMOUS by design (`allow_anonymous: true`): a catalogue store is public by
  construction, and a container that was never given any authority must still converge its
  material. A caller that passes a token source keeps it — anonymity is only the answer to
  having none. The AMBIENT account of the forge config (`:pilot_forge`, which a release always
  carries) is not a source this read asks for: it is resolved through the authority rail, which
  serves only fleet humans, and the tool door runs as `nobody` — it would turn a public read into
  a refusal (`:not_a_worker`) on every machine.

  `opts` are forwarded to the forge client. `:store_repo`, `:base_url`, `:bundled`, `:forge_repo`
  and `:forge_files` are the test seams and never reach it.
  """
  @spec mesure(keyword()) :: {:ok, [signature()]} | {:absent, String.t()} | {:error, term()}
  def mesure(opts \\ []) do
    depot = Keyword.get(opts, :store_repo, Catalogue.store_repo())
    embarque = Keyword.get(opts, :bundled, Catalogue.bundled_name())

    lecteurs = %{
      repo: Keyword.get(opts, :forge_repo, ForgeRepo),
      files: Keyword.get(opts, :forge_files, Files),
      # `put_new`, so a caller that HAS an authority keeps it: this is the answer to having no
      # token, never a downgrade of one that was named. `account: nil` masks the AMBIENT account
      # only (the client merges these opts over `:pilot_forge`) — the anonymous answer is LAST in
      # the resolution, and an ambient account would always outrank it.
      opts:
        opts
        |> Keyword.drop([:store_repo, :base_url, :bundled, :forge_repo, :forge_files])
        |> Keyword.put_new(:account, nil)
        |> Keyword.put_new(:allow_anonymous, true)
    }

    case lecteurs.repo.list_branches(depot, lecteurs.opts) do
      {:ok, branches} ->
        {:ok, signe_toutes(branches, depot, embarque, url_du_magasin(depot, opts), lecteurs)}

      {:error, :not_found} ->
        {:absent, depot}

      {:error, _} = err ->
        err
    end
  end

  # L'adresse de clone est celle du MAGASIN, pas celle du catalogue : une branche par catalogue,
  # donc un seul depot a cloner, sur la branche qui porte son nom.
  defp url_du_magasin(depot, opts) do
    base =
      Keyword.get(opts, :base_url) ||
        Keyword.get(Application.get_env(:lcars_fleet, :pilot_forge, []), :base_url) || ""

    "#{String.trim_trailing(base, "/")}/#{depot}.git"
  end

  defp signe_toutes(branches, depot, embarque, url, lecteurs) do
    Enum.flat_map(branches, &signe(&1, depot, embarque, url, lecteurs))
  end

  defp signe(%{name: branche}, depot, embarque, url, lecteurs) when branche != embarque do
    case lecteurs.files.get_file(depot, @manifest, Keyword.put(lecteurs.opts, :ref, branche)) do
      {:ok, %{content: yaml}} ->
        identifie(Catalogue.manifest_name(yaml), branche, depot, url, lecteurs)

      # Pas de manifeste : la branche par defaut du magasin porte un README, et c'est normal.
      {:error, :not_found} ->
        []

      {:error, raison} ->
        Logger.warning(
          "CatalogueMaterial: #{depot}:#{branche} carries a #{@manifest} that could not be read " <>
            "(#{inspect(raison)}) — HELD, and its local material is left exactly as it is."
        )

        [%{gravite: :hold, nom: branche, arg: "manifeste"}]
    end
  end

  # La branche du catalogue embarque, et toute entree dont la forme n'est pas celle d'une branche.
  defp signe(_entree, _depot, _embarque, _url, _lecteurs), do: []

  defp identifie({:ok, branche}, branche, depot, url, lecteurs) do
    proprietaire(lecteurs.repo.org_exists?(branche, lecteurs.opts), branche, depot, url)
  end

  defp identifie({:ok, autre}, branche, depot, _url, _lecteurs) do
    [
      %{
        gravite: :warn,
        nom: branche,
        arg:
          "#{depot}:#{branche} se déclare « #{autre} » — ce n'est pas le magasin de #{branche}, " <>
            "il n'est pas signé et rien n'est cloné sous ce nom"
      }
    ]
  end

  defp identifie({:error, :no_name_in_manifest}, branche, depot, _url, _lecteurs) do
    [
      %{
        gravite: :warn,
        nom: branche,
        arg:
          "#{depot}:#{branche} répond, mais son #{@manifest} ne déclare aucun « name: » en " <>
            "COLONNE ZÉRO — non signé. En YAML un « name: » indenté appartient à la clé du dessus"
      }
    ]
  end

  # L'ORG DU CATALOGUE EST L'AUTRE MOITIE DE L'INSTALLATION. 404 = pas d'org, donc pas installe ;
  # une absence de reponse ne conclut rien, et son materiel survit au balayage.
  defp proprietaire({:ok, true}, branche, _depot, url),
    do: [%{gravite: :ok, nom: branche, arg: url}]

  # ⚠ UNE BRANCHE QUI DISPARAIT DE LA LISTE FAIT EFFACER SON MATERIEL, ET CE CAS-CI LE FAISAIT SANS
  # UN MOT. Rendre `[]` melangeait deux faits que rien ne distinguait ensuite : « cette entree n'est
  # pas un catalogue » (une branche par defaut, le catalogue embarque — legitimement muets) et « ce
  # catalogue a bien un manifeste a son nom, mais son org n'existe pas ». Le second est le seul cas
  # ou de la matiere INSTALLEE est retiree sur une reponse de la forge, et c'est celui ou l'operateur
  # a besoin d'une phrase : l'org renommee et l'org supprimee rendent le meme 404 qu'une installation
  # jamais faite. WARN est exactement ce vocabulaire — « la branche a repondu et n'est PAS un
  # magasin ; rien n'est clone, rien n'est retenu » —, donc le materiel part comme avant, dit.
  defp proprietaire({:ok, false}, branche, depot, _url) do
    [
      %{
        gravite: :warn,
        nom: branche,
        arg:
          "#{depot}:#{branche} porte un manifeste à son nom, mais l'org « #{branche} » n'existe " <>
            "pas sur cette forge — non signé, rien n'est cloné sous ce nom. Une org renommée ou " <>
            "supprimée répond comme une installation jamais faite"
      }
    ]
  end

  defp proprietaire({:error, raison}, branche, depot, _url) do
    Logger.warning(
      "CatalogueMaterial: the org '#{branche}' of #{depot}:#{branche} could not be read " <>
        "(#{inspect(raison)}) — HELD, and its local material is left exactly as it is."
    )

    [%{gravite: :hold, nom: branche, arg: "proprietaire"}]
  end

  @doc """
  Release door: one line per signature, and a code that says what was read.

  `0` the store was read whole (the lines are the measure, an empty output means it installs
  nothing) · `2` the store is ABSENT · `1` it could not be read. The caller's protocol owns the
  verdict; this door owns the distinction between the three, which is what keeps material from
  being erased on a forge that simply did not answer.
  """
  @spec eval_check() :: no_return()
  def eval_check do
    Fleet.ReleaseDoor.claim_stdout!()

    case avec_transport(fn -> mesure() end) do
      {:ok, signatures} ->
        for %{gravite: g, nom: n, arg: a} <- signatures,
            do: IO.puts("#{String.upcase(to_string(g))}\t#{n}\t#{a}")

        System.halt(0)

      {:absent, depot} ->
        IO.puts(:stderr, "ABSENT #{depot}")
        System.halt(2)

      # LE DEPOT EN PREMIER, MEME FORME QUE « ABSENT <depot> », et pour la meme raison : c'est
      # l'objet que l'operateur doit aller voir. Sans lui, l'appelant ne pouvait nommer que « le
      # magasin des catalogues », sa propre chaine par defaut.
      {:error, raison} ->
        IO.puts(:stderr, "UNREADABLE #{Catalogue.store_repo()} #{inspect(raison)}")
        System.halt(1)
    end
  end

  # Une porte `eval` charge l'app sans la demarrer : req et le pool Finch de la forge se montent ici.
  defp avec_transport(fun) do
    with {:ok, _} <- Application.ensure_all_started(:req),
         {:ok, _} <- Supervisor.start_link([Fleet.Forge.finch_spec()], strategy: :one_for_one) do
      fun.()
    else
      {:error, raison} -> {:error, {:transport, raison}}
    end
  end
end
