defmodule Fleet.Roster do
  # ⚠ CE MODULE N'EST PAS DU CODE DE BOOT, et le ranger sous la racine OTP coute cher le jour ou il
  # doit lire une identite de forge : la racine devrait alors declarer `Fleet.Credentials` dans ses
  # deps, c'est-a-dire ANNONCER DANS LE GRAPHE QUE LE BOOT CONNAIT LES IDENTITES — faux, et faux
  # pour toujours, au benefice d'un seul emetteur.
  #
  # ⚖ ARBITRAGE USER : un domaine a lui dit ce qu'il est — la PROJECTION du roster de forge d'un
  # catalogue — et porte ses propres deps sans en preter aucune a la racine. La liste de deps d'une
  # boundary est l'enonce d'honnetete du graphe : elle doit nommer ce dont LE DOMAINE a besoin,
  # jamais ce dont un locataire a besoin.
  use Boundary,
    deps: [Fleet.CapProfile, Fleet.Catalogue, Fleet.Credentials, Fleet.ReleaseDoor],
    exports: []

  @moduledoc """
  Reads the forge roster OF A CATALOGUE — the roles a deployment must enroll before that catalogue
  can work — without starting a fleet.

  ## The list this replaces

  The roster existed in THREE hand-held copies outside the catalogue: `forge.tf` (the accounts),
  `provision-role-tokens.sh` (the token mint) and `provision-lib.sh` (`PROV_ROLES`, which WINS on
  deploy). `mix lcars.contracts.check`'s `roles.provisioning_locked` measures their equality with
  the reference catalogue, and the comment on the third one names the exit it was waiting for:
  *"d'ici sa derivation, cette ligne se tient a la main"*.

  Held by hand, the list is wrong twice a year — the same defect landed on `eng_doc` and again on
  its rename to `scribe`, both times as a producer looping on `role_token_unavailable`. Held by
  hand against a SECOND catalogue, it is wrong by construction: nothing in the reference's roster
  describes someone else's business.

  So the catalogue answers instead. It already carries the declaration
  (`metadata.forge_identity`, absent = true) — this module only makes it readable from outside a
  running fleet, which is where a provisioning script stands.

  ## What it does NOT do, and the line matters

  It returns NAMES. It does not write the tofu recipe, and nothing about a catalogue should: the
  recipe carries what an account is ALLOWED to be — no org creation, no server-side git hooks, no
  local import, the org and team layout, the system account. Those are contract, and a catalogue is
  the one thing an operator swaps. Generating them FROM a catalogue would hand a replaceable file
  the authority to widen them, which is the exact inversion the runtime/catalogue frontier exists to
  prevent.

  The split: the catalogue says WHO exists, the recipe says what existing gets you.
  """

  @doc """
  Forge-identity role names of the catalogue at `root`, sorted.

  Swaps `:lcars_fleet, :catalogue_root` for the duration and restores it — the same borrow-and-return as
  `Fleet.Application.CatalogueVerify.verify/1`, so a caller inside a live node cannot leave the
  fleet pointed somewhere else.
  """
  @spec list(Path.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list(root) when is_binary(root) do
    prev = Application.fetch_env(:lcars_fleet, :catalogue_root)
    Application.put_env(:lcars_fleet, :catalogue_root, root)

    try do
      Fleet.CapProfile.forge_identity_roles()
    after
      restore(prev)
    end
  end

  @doc """
  The four lists the forge recipe takes as input, derived from the catalogue at `root`.

      %{"roles" => [...], "writers" => [...], "judges" => [...], "externals" => [...]}

  The grouping rule, and it lives HERE rather than in a shell so it can be tested:

    * `externals` — the ReservedSeats. A seat holds a name; it never acts.
    * `judges` — `brief_kind: judge` and no structural capability. They render verdicts and put
      nothing in the repository.
    * `writers` — everything else: the producers, the delegate, the signer.

  `roles` is the union, and it is the account roster — a role in no team still needs its account.

  This is the shape tofu reads natively from a `*.auto.tfvars.json`, which is why it is emitted as
  data and not as a recipe: the recipe declares what an account is ALLOWED to be (no org creation,
  no server-side git hooks, the org and team layout), and those are contract. A catalogue names its
  people; it does not get to widen what being one of them permits.
  """
  @spec tfvars(Path.t()) :: {:ok, map()} | {:error, term()}
  def tfvars(root) when is_binary(root) do
    prev = Application.fetch_env(:lcars_fleet, :catalogue_root)
    Application.put_env(:lcars_fleet, :catalogue_root, root)

    try do
      with {:ok, roster} <- Fleet.CapProfile.forge_roster(),
           {:ok, cat} <- catalogue_name(),
           {:ok, login_of} <- login_projection() do
        names = Map.new(roster, fn r -> {login_of.(r.name), r.name} end)

        {system_logins, business_logins} =
          roster
          |> Enum.map(&login_of.(&1.name))
          |> Enum.split_with(&String.starts_with?(&1, "system_"))

        {:ok,
         %{
           # DEUX listes, parce que les comptes n'ont pas la meme DUREE DE VIE. Les `system_*` sont
           # une autorite d'INSTANCE — la meme dans toutes les orgs, creee une fois ; les metier
           # appartiennent a ce catalogue-ci. Les fondre ferait tenter leur creation a chaque
           # enrolement d'un catalogue, et Gitea rend « user already exists » (mesure).
           "roles" => business_logins,
           "system_roles" => system_logins,
           "writers" =>
             roster |> Enum.reject(&(&1.seat? or &1.judge?)) |> Enum.map(&login_of.(&1.name)),
           "judges" =>
             roster
             |> Enum.filter(&(&1.judge? and not &1.seat?))
             |> Enum.map(&login_of.(&1.name)),
           "externals" => roster |> Enum.filter(& &1.seat?) |> Enum.map(&login_of.(&1.name)),
           # login -> nom du ROLE, pour que la recette pose `full_name`. Le prefixe disparait alors
           # de l'UI (`[ui] DEFAULT_SHOW_FULL_NAME`), et ne subsiste que dans l'URL et l'API.
           "role_names" => names,
           # L'ORG qui portera les projets de ce catalogue, et c'est son NOM : « ou vit ce projet »
           # repond alors a « quel catalogue le traite », interrogeable sans LCARS. La recette le
           # recoit d'ici plutot que de le tenir en litteral — un litteral ne peut nommer qu'une org.
           "org" => cat,
           # ⚠ LE COMPTE SYSTEME SE CONSOMME, IL NE SE RECOPIE PAS. Un `variable "system_account"`
           # a defaut litteral cote recette n'est alimente par aucun `.tfvars` et compare par aucun
           # verrou — alors que ce compte est dans la team `Owners` de l'org, que son email passe le
           # gate d'identite de commit et qu'il est le `forge_push_account` par defaut. LE COMPTE
           # QUI POSSEDE L'ORG NAITRAIT D'UN NOM QUE PERSONNE NE TIENT.
           #
           # ⚖ Arbitrage user : l'autorite est `ForgeIdentity` — l'identite du compte (email,
           # signature, `allowed_emails/2`) en derive et ne peut pas s'en detacher. La recette le
           # RECOIT donc, comme elle recoit deja l'org et les quatre listes.
           "system_account" => Fleet.Credentials.ForgeIdentity.system_identity().name
         }}
      end
    after
      restore(prev)
    end
  end

  # `<catalogue>_<role>`, et le prefixe suit le TIER, pas le fichier qui gagne. Un catalogue metier
  # peut livrer son propre `architect.yaml` pour elargir ses outils — c'est legal — et ce profil
  # supersede celui du systeme. Le compte reste `system_architect` pour autant : `architect` est une
  # autorite systeme, la MEME dans toutes les orgs, et le rester est le sens du tier. Ce qui decide
  # est donc ou le nom est DECLARE EN PREMIER, ce que `forge_roster/1` lit seul puisqu'il prend UN
  # repertoire.
  #
  # Le souligne separe les deux moities, d'ou son interdiction des deux cotes : `Fleet.Catalogue`
  # refuse un nom de catalogue qui en porte, et le nom de role est verifie ici. Et Gitea plafonne un
  # login a 40 caracteres (mesure), donc la composition l'est aussi.
  #
  # THE RULE ITSELF NOW LIVES IN `Fleet.CapProfile.forge_login/1`, and moving it there was the fix
  # for a real defect: held here, only the PROVISIONING side could read it. The accounts were
  # created as `<tier>_<role>` while the runtime went on addressing roles by their bare name, so
  # `request_review` asked the forge for a `qualifier` that does not exist and the PR got no judge.
  # A projection that only the writer of a name can compute is a name the reader cannot use.
  defp login_projection do
    with {:ok, _} <- catalogue_name() do
      {:ok,
       fn role ->
         case Fleet.CapProfile.forge_login(role) do
           {:ok, login} ->
             login

           {:error, reason} ->
             raise "CatalogueRoles: no forge login for #{role}: #{inspect(reason)}"
         end
       end}
    end
  end

  defp catalogue_name do
    case Fleet.Catalogue.name() do
      n when is_binary(n) -> {:ok, n}
      _ -> {:error, :catalogue_declares_no_name}
    end
  end

  @doc """
  The RELEASE door for the tfvars: print the JSON on stdout and halt 0, reason on stderr and halt 1.

      bin/lcars_fleet eval 'Fleet.Roster.eval_tfvars("/cat")'
  """
  @spec eval_tfvars(Path.t()) :: no_return()
  def eval_tfvars(root) when is_binary(root) do
    # ⚠ CE FLUX EST DU JSON, ET IL EST REDIRIGE DANS UN FICHIER QUE TOFU LIT
    # (`roles.auto.tfvars.json`, `cmd_install`), puis dans `jq` par `prov_roles` (provision-lib).
    # Une ligne de log sur stdout n'y fait pas une sortie bavarde : elle fait un JSON invalide, donc
    # une recette sans roster ou un mint sans comptes. `list/1` et `tfvars/1` logguent tous deux.
    Fleet.ReleaseDoor.claim_stdout!()

    case tfvars(root) do
      {:ok, %{"roles" => []}} ->
        IO.puts(
          :stderr,
          "catalogue #{root}: no role declares a forge identity — nothing to enroll"
        )

        System.halt(1)

      {:ok, vars} ->
        IO.puts(Jason.encode!(vars, pretty: true))
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "catalogue #{root}: roster unreadable (#{inspect(reason)})")
        System.halt(1)
    end
  end

  @doc """
  The RELEASE door: print one role per line and halt 0, or print the reason on stderr and halt 1.
  Called from the image entrypoint via a release eval —

      bin/lcars_fleet eval 'Fleet.Roster.eval_main("/cat")'

  One name per line, nothing else on stdout: the consumer is a shell that captures it into a
  variable. Diagnostics go to stderr precisely so that capturing stdout on a failure yields the
  EMPTY string rather than an error message parsed as a role name — a roster silently containing
  "catalogue root not readable" would create forge accounts by that name.
  """
  @spec eval_main(Path.t()) :: no_return()
  def eval_main(root) when is_binary(root) do
    Fleet.ReleaseDoor.claim_stdout!()

    case list(root) do
      {:ok, []} ->
        IO.puts(
          :stderr,
          "catalogue #{root}: no role declares a forge identity — nothing to enroll"
        )

        System.halt(1)

      {:ok, roles} ->
        for role <- roles, do: IO.puts(role)
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "catalogue #{root}: roster unreadable (#{inspect(reason)})")
        System.halt(1)
    end
  end

  defp restore(:error), do: Application.delete_env(:lcars_fleet, :catalogue_root)
  defp restore({:ok, value}), do: Application.put_env(:lcars_fleet, :catalogue_root, value)
end
