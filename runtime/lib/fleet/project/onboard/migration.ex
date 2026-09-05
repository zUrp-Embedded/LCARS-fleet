defmodule Fleet.Project.Onboard.Migration do
  @moduledoc """
  Deplacer un projet d'un catalogue a un autre, et faire reconverger un conteneur sur ce que la forge
  porte vraiment.

  Deux rails, une seule question : « l'etat sur disque et l'etat sur la forge disent-ils la meme
  chose ? ». `migrate/3` repond en DEPLACANT, la reconciliation repond en CONSTATANT — chaque verbe
  a sa forme `eval_*` qui rend le diagnostic sans rien ecrire, parce que `bin/lcars` n'a aucun
  acces au BEAM et lit un verdict, pas un effet.
  """

  alias Fleet.Project.GitOps
  alias Fleet.Project.Onboard
  alias Fleet.Project.Onboard.Faces
  alias Fleet.Project.Onboard.Refute
  alias Fleet.Project.Onboard.Repo

  require Logger

  @doc """
  MIGRE un projet d'un catalogue vers un autre — le transfert forge ET le repointage local.

  L'org d'un projet EST le nom de son catalogue : migrer, c'est donc transferer le depot dans l'org
  du catalogue cible. Le transfert est un seul appel et tout survit (issues, PR, labels, protection,
  attribution) ; ce qui NE suit pas est ce qu'on ne veut pas voir suivre — les droits se REDERIVENT
  des teams de l'org d'arrivee, donc les roles de l'ancien catalogue perdent l'ecriture et leur
  historique reste a leur nom, ce qui est la verite : ce travail-la a bien ete fait par ce catalogue.

  Les trois faces locales sont clees par le NOM du projet, pas par l'org : elles survivent. Mais leur
  `origin` pointe l'ancienne URL et ne vit plus que par la redirection `301` de Gitea — les repointer
  fait partie du geste, sans quoi la migration laisse un projet qui marche par accident.

  Ce que cette fonction NE fait pas, et ne peut pas faire : attendre la quiescence. Elle n'en a pas
  besoin — un catalogue ne change pas sous un projet vivant (les images gelent au boot, et le boot
  refuse une carte nommant un role absent). Ce qui reste est le cas ou l'operateur migre pendant
  qu'un step-run est ouvert : la PR en vol a ete produite par un role que le nouveau catalogue ne
  porte pas, et c'est a lui de le savoir.
  """
  @spec migrate(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def migrate(full_name, target_catalogue, opts \\ [])
      when is_binary(full_name) and is_binary(target_catalogue) do
    name = Fleet.Layout.project_name(full_name)
    dirs = Faces.face_dirs(name, opts)

    # La loi d'ordre, la meme qu'a l'import : les refus PURS et LOCAUX d'abord, la forge ensuite.
    # `refute_store` lit le manifeste de la cible ; le faire avant `require_target_installed` ferait
    # payer un aller-retour a une migration refusee sur un fait que le disque portait deja.
    with :ok <- refute_same_catalogue(full_name, target_catalogue),
         :ok <- require_target_installed(target_catalogue),
         :ok <- Refute.refute_store(full_name, opts),
         {:ok, new_full_name} <-
           Repo.repo_mod(opts).transfer_repo(full_name, target_catalogue, Repo.fc_opts(opts)),
         {:ok, url} <- Repo.repo_url(new_full_name, opts),
         {:ok, repointed} <- repoint_faces(dirs, url) do
      Logger.info(
        "ProjectOnboard: #{full_name} MIGRE vers #{new_full_name} — " <>
          "#{length(repointed)}/#{map_size(dirs)} faces repointees sur #{url}"
      )

      {:ok,
       %{
         repo: new_full_name,
         from: full_name,
         faces: Enum.reverse(repointed),
         absent: Enum.sort(Map.values(dirs) -- repointed)
       }}
    end
  end

  defp refute_same_catalogue(full_name, target) do
    case String.split(full_name, "/") do
      [^target | _] -> {:error, {:already_in_catalogue, target}}
      _ -> :ok
    end
  end

  # Meme refus que l'import, et pour la meme raison : migrer vers un catalogue que ce conteneur n'a
  # pas produirait un projet dont personne ne sait lire le metier — et le poller ne decouvre que sur
  # les orgs des catalogues INSTALLES, donc le projet deviendrait invisible, pas casse.
  #
  # ⚠ DEUX ETATS, ET PAS TROIS. Une declaration locale d'ACTIVITE serait un troisieme etat entre
  # « le materiel est la » et « la forge le porte », tenu a la main. Deux etats qui repondent a la
  # meme question finissent par se contredire, et l'ecart tue une flotte entiere : mesure au banc,
  # declare actif et jamais installe, le poller derive ses orgs de la declaration et cherche des
  # jetons de role que personne n'a frappes.
  #
  # Ce qui reste tient en une phrase : le materiel est ICI ou il n'y est pas, et il n'y arrive que
  # par la forge. Le pendant forge (le preflight, plus bas) n'est PAS un
  # troisieme etat — c'est le meme fait mesure a sa source, pour le cas ou l'install a ete
  # interrompu entre l'org et le materiel.
  defp require_target_installed(target), do: Onboard.require_installed(target)

  # Rend les faces REELLEMENT repointees, pas celles qu'on visait. La difference n'est pas
  # cosmetique : sur un banc, ce geste annonce « trois faces repointees » sur un conteneur ou les
  # trois sont absentes — la moitie forge est juste, et le rapport ment. Un appelant qui
  # affiche la liste visee affirme un travail qu'il n'a pas fait.
  defp repoint_faces(dirs, url) do
    Enum.reduce_while(Map.values(dirs), {:ok, []}, fn dir, {:ok, done} ->
      if File.dir?(Path.join(dir, ".git")) do
        case GitOps.run(["-C", dir, "remote", "set-url", "origin", url], auth: false) do
          :ok -> {:cont, {:ok, [dir | done]}}
          {:error, reason} -> {:halt, {:error, {:remote_repoint_failed, dir, reason}}}
        end
      else
        # Une face absente n'est pas un echec : un projet peut n'avoir jamais ete ouvert ICI. Le
        # transfert forge a deja eu lieu, et refuser maintenant laisserait les deux moities en
        # desaccord. Elle n'entre simplement pas dans le compte rendu.
        {:cont, {:ok, done}}
      end
    end)
  end

  @doc """
  Porte RELEASE de la migration : rend un verdict sur stdout et sort par le CODE.

      bin/lcars_fleet eval 'Fleet.Project.Onboard.eval_migrate("fleet/vitrine", "web")'

  Meme forme que `CatalogueVerify.eval_main/1`, et pour la meme raison : `bin/lcars` n'a aucun acces
  forge, et lui en donner un ferait d'une commande locale un acteur distant. Le conteneur, lui, porte
  deja les jetons et la config.
  """
  @spec eval_migrate(String.t(), String.t()) :: no_return()
  def eval_migrate(full_name, target) when is_binary(full_name) and is_binary(target) do
    # `eval` LOADS the app, it does not START it: the forge HTTP pool has no supervisor here, and
    # the transfer died on `unknown registry: Fleet.Forge.Finch`. Started standalone, like the mix
    # task that already does it — never `app.start`, because a second fleet must not boot from a
    # tool. The door needs exactly this one process and starts exactly it.
    {:ok, _sup} = Supervisor.start_link([Fleet.Forge.finch_spec()], strategy: :one_for_one)

    # Le rapport de cette porte est lu par un operateur, pas parse — mais un « migre : a -> b »
    # entrelace d'avertissements du transfert se lit tout aussi mal. Meme regle, meme geste.
    Fleet.ReleaseDoor.claim_stdout!()

    case migrate(full_name, target) do
      {:ok, %{repo: new_name, faces: faces, absent: absent}} ->
        IO.puts("migre : #{full_name} -> #{new_name}")
        for d <- faces, do: IO.puts("  origin repointe : #{d}")

        # Une face jamais ouverte ICI est normale, et le taire ferait lire « rien a repointer »
        # comme « tout est repointe ». On dit ce qu'on n'a pas fait.
        for d <- absent, do: IO.puts("  face absente (jamais ouverte ici) : #{d}")

        System.halt(0)

      {:error, {:catalogue_not_installed, cat, gestures}} ->
        IO.puts(
          :stderr,
          "REFUSE : le catalogue #{inspect(cat)} n'est pas installe sur ce conteneur."
        )

        IO.puts(:stderr, "  #{gestures}")
        System.halt(1)

      {:error, {:already_in_catalogue, cat}} ->
        IO.puts(:stderr, "REFUSE : #{full_name} est deja dans le catalogue #{inspect(cat)}.")
        System.halt(1)

      # Gitea demande le PROPRIETAIRE du depot pour un transfert — pas l'admin, mesure : un compte
      # membre avec write recoit ce 403 mot pour mot. Le compte systeme n'est proprietaire d'aucune
      # org, par construction : c'est une identite de service, pas une autorite d'onboarding. Nomme,
      # parce qu'un tuple HTTP brut envoie l'operateur debugger la porte au lieu de lire la reponse.
      {:error, {:http, 403, %{"message" => "user should be the owner of the repo"}}} ->
        IO.puts(:stderr, "REFUSE : le compte de service n'est pas proprietaire de #{full_name}.")

        IO.puts(
          :stderr,
          "  un transfert Gitea exige le PROPRIETAIRE du depot (pas l'admin) — le compte qui"
        )

        IO.puts(:stderr, "  fait tourner la fleet est membre, pas proprietaire.")
        IO.puts(:stderr, "  il faut une identite de classe onboarding : c'est une decision de")
        IO.puts(:stderr, "  deploiement, pas un reglage de cette commande.")
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "ECHEC : #{inspect(reason)}")
        System.halt(2)
    end
  end

  @doc """
  Porte RELEASE de la reconvergence de `/home` : la forge dit quels projets existent, le disque suit.

      bin/lcars_fleet eval 'Fleet.Project.Onboard.eval_reconcile(:check)'
      bin/lcars_fleet eval 'Fleet.Project.Onboard.eval_reconcile(:apply)'

  L'INVENTAIRE N'EXISTE QUE SUR LA FORGE, et c'est ce qui rend cette porte necessaire.
  `list_projects/1` enumere le DISQUE (`code_root`) : sur un conteneur neuf — ou apres un nuke, ou
  pour un second humain qui arrive sur une fleet deja peuplee — il n'y a rien a enumerer, alors que
  les projets, eux, sont intacts. Aucun verbe n'est ecrit ici : `import/2` est deja le rail
  forge→conteneur et deja idempotent. Ce qui n'existe nulle part ailleurs, c'est la LISTE.

  Sortie : un mot par projet, sur une ligne. `check` ne touche rien (`DEJA` / `MANQUE`), `apply`
  importe (`DEJA` / `IMPORTE`). Un projet en echec n'arrete pas les autres — un conteneur auquel il
  manque neuf projets sur dix doit en recuperer neuf, pas zero.

  Codes de sortie : `0` tout converge · `1` au moins un `ECHEC` · `2` au moins un `MANQUE` et aucun
  echec. Le module de provisioning qui joue cette porte lit les LIGNES et rend son propre verdict ;
  ces codes sont la pour l'operateur qui l'appelle a la main.
  """
  @spec eval_reconcile(:check | :apply) :: no_return()
  def eval_reconcile(mode) when mode in [:check, :apply] do
    # Meme raison qu'`eval_migrate` : `eval` CHARGE l'app, il ne la demarre pas, et le premier appel
    # forge meurt alors en `unknown registry: Fleet.Forge.Finch`.
    {:ok, _sup} = Supervisor.start_link([Fleet.Forge.finch_spec()], strategy: :one_for_one)

    # Le module qui lit cette porte parse un mot par ligne : `stdout` est un format de fil, pas une
    # console. Le pourquoi et la mesure vivent dans `Fleet.ReleaseDoor`.
    Fleet.ReleaseDoor.claim_stdout!()

    entries = reconcile(mode)

    case entries do
      [] -> IO.puts("RIEN aucun projet declare dans les catalogues installes")
      _ -> Enum.each(entries, &IO.puts(reconcile_line(&1)))
    end

    cond do
      Enum.any?(entries, &(&1.status == :failed)) -> System.halt(1)
      Enum.any?(entries, &(&1.status == :missing)) -> System.halt(2)
      true -> System.halt(0)
    end
  end

  @doc """
  L'etat de reconvergence de chaque projet des catalogues installes — la porte sans la sortie.

  Rend une liste de `%{repo:, status:, reason:}`. `:check` lit (`:present` / `:missing`), `:apply`
  agit (`:already` / `:imported`), les deux rendent `:failed` avec sa raison.

  LE FILTRE EST `.lcars.json` SUR `main`, et il ne se derive pas du nom. Une org de catalogue porte
  aussi des depots qui ne sont pas des projets — a commencer par le `catalogue` qui la signe — et les
  importer creerait trois faces autour d'un depot qu'aucun humain n'a ouvert. Mesure sur la forge du
  banc : un projet rend `200` sur ce fichier, le magasin rend `404`.

  La liste de ces depots n'est PAS fermee, et c'est la raison d'etre du filtre par propriete : un
  humain depose ce qu'il veut dans son org, et un garde qui enumererait des noms devrait etre corrige
  a chaque depot nouveau — et a chaque depot retire, ce qui arrive aussi. Le filtre par propriete ne
  bouge d'aucune ligne dans les deux cas.
  """
  @spec reconcile(:check | :apply, keyword()) :: [
          %{repo: String.t(), status: atom(), reason: term()}
        ]
  def reconcile(mode, opts \\ []) when mode in [:check, :apply] do
    Enum.flat_map(Onboard.installed_orgs(), &reconcile_org(&1, mode, opts))
  end

  # UNE ORG ILLISIBLE EST UN ECHEC, PAS UNE ORG VIDE. Rendre `[]` ferait lire « rien a importer » a
  # un `check` qui n'a simplement pas su demander, et les autres orgs, elles, restent lisibles.
  defp reconcile_org(org, mode, opts) do
    case Repo.repo_mod(opts).list_org_repos(org, Repo.fc_opts(opts)) do
      {:ok, names} ->
        names |> Enum.sort() |> Enum.flat_map(&reconcile_repo(&1, mode, opts))

      {:error, reason} ->
        [%{repo: "#{org}/*", status: :failed, reason: {:org_unreadable, reason}}]
    end
  end

  defp reconcile_repo(full_name, mode, opts) do
    case declared_project?(full_name, opts) do
      {:ok, true} -> [converge_project(full_name, mode, opts)]
      {:ok, false} -> []
      {:error, reason} -> [%{repo: full_name, status: :failed, reason: reason}]
    end
  end

  defp declared_project?(full_name, opts) do
    file = Fleet.Layout.project_declaration_file()
    fc = Keyword.put(Repo.fc_opts(opts), :ref, "main")

    case Repo.files_mod(opts).get_file(full_name, file, fc) do
      {:ok, _} -> {:ok, true}
      {:error, :not_found} -> {:ok, false}
      # Une forge muette ne prouve pas l'absence de declaration : la nommer ici evite qu'un projet
      # bien reel disparaisse de l'inventaire sur un timeout.
      {:error, reason} -> {:error, {:declaration_unreadable, file, reason}}
    end
  end

  defp converge_project(full_name, :check, opts) do
    dirs = Faces.face_dirs(Fleet.Layout.project_name(full_name), opts)

    # LES TROIS FACES, PAS UNE. Un projet dont il manque une seule face n'est pas ouvert ici : son
    # architecte monterait un chemin absent. `check` ne tranche pas plus finement — il dit qu'il y a
    # a faire, et `apply` dit quoi, avec le refus exact d'`import/2` si l'etat est a moitie pose.
    if Enum.all?([dirs.code, dirs.ops, dirs.workshop], &File.dir?/1),
      do: %{repo: full_name, status: :present, reason: nil},
      else: %{repo: full_name, status: :missing, reason: nil}
  end

  # ⚠ L'ARCHITECTE NE S'ASSURE PAS D'ICI, ET CE N'EST PAS UN RACCOURCI. Mesure au banc : l'import
  # pose ses trois faces puis MEURT sur
  # `GenServer.call(Fleet.Spawner.Supervisor, …) ** (EXIT) no process` — `eval` charge l'app, il ne
  # la demarre pas, donc aucun superviseur de spawn n'existe dans cette VM. La convergence
  # aboutit sur le disque et rend un echec, sans compensation, a la derniere jambe.
  #
  # Ce qui prend la suite existe deja : le poller de la fleet assure l'architecte de chaque projet
  # qu'il sert (`Architect.ensure_alive/2`, a chaque tour). La reconvergence pose les FACES ; les
  # pods appartiennent au cycle de vie d'une fleet vivante, qui n'est pas celui d'un provisionnement.
  defp converge_project(full_name, :apply, opts) do
    opts =
      Keyword.put_new(opts, :ensure_architect, fn _repo, _o ->
        {:deferred, "aucune fleet dans cette VM — le poller l'assure au demarrage"}
      end)

    # QUALIFIE OBLIGATOIREMENT, et pour deux raisons qui se cumulent depuis le decoupage :
    # `import/2` nu est la forme speciale du compilateur, pas ce verbe — et le verbe vit maintenant
    # sur la facade du domaine, plus dans ce module.
    case Onboard.import(full_name, opts) do
      {:ok, %{idempotent: true}} -> %{repo: full_name, status: :already, reason: nil}
      {:ok, _} -> %{repo: full_name, status: :imported, reason: nil}
      {:error, reason} -> %{repo: full_name, status: :failed, reason: reason}
    end
  end

  defp reconcile_line(%{repo: repo, status: :failed, reason: reason}),
    do: "ECHEC   #{repo} — #{inspect(reason)}"

  defp reconcile_line(%{repo: repo, status: status}) do
    word =
      case status do
        :present -> "DEJA"
        :already -> "DEJA"
        :imported -> "IMPORTE"
        :missing -> "MANQUE"
      end

    "#{String.pad_trailing(word, 7)} #{repo}"
  end

  @doc """
  Reprojects the canonical `main` protection for a fully seeded project.

  The rule is sized from the current card jury, rejects direct pushes, dismisses stale approvals
  and blocks rejected reviews. Unseeded repositories and the configured project template are left
  untouched.
  """
  @spec reconcile_main_protection(String.t(), keyword()) :: :ok | {:error, term()}
  def reconcile_main_protection(repo, forge_opts) when is_binary(repo) do
    opts = Keyword.put(forge_opts, :forge_opts, forge_opts)

    case seeded_project?(repo, opts) do
      {:ok, true} -> Faces.protect_main(repo, opts)
      {:ok, false} -> :ok
      {:error, reason} -> {:error, {:seeded_unreadable, reason}}
    end
  end

  # ⚠ TROIS ETATS, TROIS REPONSES : seede (protege), prouve non seede (rien a faire, vrai `:ok`),
  # illisible (on ne sait pas — on le DIT et l'appelant retentera). Un `false` sur une forge
  # illisible enverrait `reconcile_main_protection/2` dans son `else` rendre **`:ok`** : « rien a
  # faire ici », mot pour mot ce que rend un depot legitimement non seede — aucune trace, le Poller
  # horodate le depot comme reconcilie, et la protection de `main` n'est jamais posee.
  #
  # ⚠ PAS DE CAS PARTICULIER POUR UN DEPOT TEMPLATE : rien ne cree `<catalogue>/project-template`,
  # donc rien n'a besoin d'etre exclu pour que la reconciliation ne lui pose pas une protection de
  # `main` dimensionnee sur un jury qui ne le concerne pas.
  #
  # Un garde par PROPRIETE, pas par nom : un depot qui ne porte pas de branche `ops` n'est pas un
  # projet, quel que soit son nom. Le magasin d'un catalogue n'en porte pas — il est donc hors de
  # portee, sans que rien n'ait a le nommer.
  defp seeded_project?(repo, opts) do
    Repo.repo_mod(opts).branch_exists?(repo, "ops", Repo.fc_opts(opts))
  end
end
