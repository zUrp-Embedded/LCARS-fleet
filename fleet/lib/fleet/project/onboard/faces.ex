defmodule Fleet.Project.Onboard.Faces do
  @moduledoc """
  Les TROIS faces d'un projet sur la boite, et les gestes git qui les posent : creer, cloner,
  committer, pousser, proteger `main`, et defaire ce qu'un geste interrompu a laisse.

  Un projet LCARS est un depot sur la forge et trois depots locaux — `code` (branche `main`, le
  livrable), `ops` (orphelin, le RELEVE : briefs, verdicts, provenance) et `workshop` (orphelin,
  l'ATELIER). Ce module est la seule autorite sur leurs racines : une deuxieme copie de
  `@code_root` serait une deuxieme facon de deplacer un projet, dont une seule suivrait un
  changement de layout.

  Tout est `@doc false` — c'est le vocabulaire de la famille onboarding, public seulement parce
  que les gestes vivent dans des modules voisins.
  """

  alias Fleet.Project.GitOps
  alias Fleet.Project.Onboard.Repo
  alias Fleet.Project.Onboard.Scaffold
  alias Fleet.Project.Roles

  require Logger

  @code_root Fleet.Layout.code_root()
  @ops_root Fleet.Layout.ops_root()
  @workshop_root Fleet.Layout.workshop_root()

  @doc false
  @spec code_root(keyword()) :: String.t()
  def code_root(opts), do: Keyword.get(opts, :code_root, @code_root)

  # onboarding author = the system (it GENERATES the scaffold) — not the arch (mere relay), not the user
  # (wrote nothing). committer = the human (git config) traces who initiated.
  # System identity: SINGLE AUTHORITY = Fleet.Credentials.ForgeIdentity.system_identity/0
  # (a name/email retyped here would be a divergence in the making with the gate).
  @doc false
  @spec onboard_author() :: %{name: String.t(), email: String.t()}
  def onboard_author, do: Fleet.Credentials.ForgeIdentity.system_identity()

  @doc false
  @spec compensate_dir(String.t()) :: :removed | :removal_incomplete | :absent
  def compensate_dir(dir) do
    if File.exists?(dir) do
      case nuke_dir(dir) do
        :ok -> :removed
        {:error, _} -> :removal_incomplete
      end
    else
      :absent
    end
  end

  # LA COMPENSATION SE DIT DANS LE RETOUR, pas seulement dans un log — parce que l'appelant decide
  # a partir du retour, et que ce qu'il en deduit ici est « je peux retenter proprement ». Tant que
  # tout a ete retire, c'est vrai et l'erreur d'origine passe intacte. Des qu'une suppression
  # echoue, elle devient fausse : le depot d'un tiers porte une branche que cette tentative y a
  # laissee, et le retry la lira comme preexistante. Ce cas-la porte donc son propre nom.
  #
  # ⚠ On ne supprime QUE `published`. Une branche clonee etait deja la ; une branche dont la
  # lecture a echoue n'a jamais ete touchee (`ensure_face` refuse avant d'ecrire).
  @doc false
  @spec undo_published(String.t(), [String.t()], term(), keyword()) :: {:error, term()}
  def undo_published(_full_name, [], reason, _opts), do: {:error, reason}

  def undo_published(full_name, published, reason, opts) do
    outcomes =
      Enum.map(published, fn branch ->
        {branch, Repo.repo_mod(opts).delete_branch(full_name, branch, Repo.fc_opts(opts))}
      end)

    case Enum.reject(outcomes, &match?({_b, {:ok, _}}, &1)) do
      [] ->
        Logger.warning(
          "ProjectOnboard: import #{full_name} FAILED (#{inspect(reason)}) — forge compensated: " <>
            "#{inspect(Enum.map(outcomes, fn {b, {:ok, o}} -> {b, o} end))}"
        )

        {:error, reason}

      left ->
        Logger.error(
          "ProjectOnboard: import #{full_name} FAILED (#{inspect(reason)}) and its forge " <>
            "compensation did NOT complete — branches pushed by this attempt SURVIVE on a " <>
            "third-party repo: #{inspect(left)}"
        )

        {:error, {:import_not_compensated, reason, left}}
    end
  end

  @doc false
  @spec set_origin(String.t(), String.t()) :: :ok | {:error, term()}
  def set_origin(dir, url) do
    case GitOps.read(["-C", dir, "config", "--get", "remote.origin.url"]) do
      {:ok, _present} -> GitOps.run(["-C", dir, "remote", "set-url", "origin", url], auth: false)
      {:error, _} -> GitOps.run(["-C", dir, "remote", "add", "origin", url], auth: false)
    end
  end

  @doc false
  @spec nuke_dir(String.t()) :: :ok | {:error, term()}
  def nuke_dir(dir) do
    case File.rm_rf(dir) do
      {:ok, _} ->
        :ok

      {:error, reason, path} ->
        Logger.warning("ProjectOnboard: reset could not fully remove #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # L'INVENTAIRE SE CONSTRUIT EN AVANCANT, il ne se prend pas d'avance : une branche n'entre dans la
  # liste que quand son push a REUSSI, donc chaque entree est une mutation prouvee de cette
  # tentative. Un etat releve avant la boucle serait deja perime au premier push, et c'est
  # exactement sur cet ecart qu'une compensation supprime ce qu'elle n'a pas cree.
  #
  # L'echec porte l'inventaire avec lui (`{:error, reason, published}`) parce que les faces sont
  # posees EN SEQUENCE : `ops` peut etre publiee avant que `workshop` echoue, et c'est le cas exact
  # que la fiche 6-124 decrit.
  #
  # ⚠ LE MODE EST UN FAIT DE LAYOUT, ET IL SE DECLARE PLUTOT QUE DE SE LAISSER A L'UMASK. Les faces
  # vivent sous des racines PARTAGEES, donc un projet ouvert par un humain est vu par les autres.
  # `workshop` est la seule montee en **rw** : heritant son mode de l'umask, le second humain a le
  # groupe mais PAS le bit d'ecriture, et ses pods meurent a la premiere ecriture avec une erreur
  # qui accuse bwrap. `ops` est montee `ro` et garde le mode plus etroit — le declarer ici est ce
  # qui rend la difference LISIBLE.
  @doc false
  @spec ensure_writer_faces(String.t(), String.t(), map(), String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, term(), [String.t()]}
  def ensure_writer_faces(full_name, url, dirs, name, opts) do
    faces = [
      %{dir: dirs.ops, branch: Fleet.Layout.ops_branch(), template: "ops", mode: 0o2755},
      %{
        dir: dirs.workshop,
        branch: Fleet.Layout.workshop_branch(),
        template: "workshop",
        mode: 0o2775
      }
    ]

    Enum.reduce_while(faces, {:ok, []}, fn %{branch: branch} = face, {:ok, published} ->
      case ensure_face(full_name, url, face, name, opts) do
        {:ok, :published} -> {:cont, {:ok, published ++ [branch]}}
        {:ok, :cloned} -> {:cont, {:ok, published}}
        {:error, reason} -> {:halt, {:error, reason, published}}
      end
    end)
  end

  @doc false
  @spec lock_main(String.t(), keyword()) :: :ok | {:error, term()}
  def lock_main(full_name, opts), do: protect_main(full_name, opts)

  @doc """
  Les contextes de statut EXIGÉS sur `main` d'un projet — l'autorité, et la seule.

  Extrait de la règle ci-dessous parce qu'un SECOND lecteur la lit : le template
  livre désormais des workflows de SONDE (`probe-*`), dont toute la protection tient à ce que leur
  contexte ne matche PAS ce glob. Une sonde renommée `CI-…` deviendrait un statut requis et son
  rouge bloquerait le merge — on aurait retiré le CI de la boucle en croyant l'augmenter.

  Le test qui garde ça (`project_template_workflows_test`) lit CETTE fonction. Recopier `"CI / *"`
  chez lui aurait fait deux vérités d'un même fait, et c'est celle du test qui aurait survécu au
  jour où celle-ci change.
  """
  @spec main_status_check_contexts() :: [String.t()]
  def main_status_check_contexts, do: ["CI / *"]

  @doc false
  @spec protect_main(String.t(), keyword()) :: :ok | {:error, term()}
  def protect_main(repo, opts) do
    rule = %{
      rule_name: "main",
      required_approvals: length(Roles.project_jury(repo, opts)),
      dismiss_stale_approvals: true,
      block_on_rejected_reviews: true,
      enable_push: false,
      # THE CI GATE IS THE FORGE'S, NOT THE RUNTIME'S. Measured on a live bench: a PR
      # whose head carried `CI / ci (push)` = failure was promoted, and the PR showed no check at
      # all. Two doors were open at once — nothing in `lib/` reads a commit status (the seal merges
      # on jury verdicts alone), and the forge rule had `enable_status_check: false`. The rail ran,
      # produced a verdict, and nobody was listening.
      #
      # It belongs HERE rather than in the seal: the forge IS the state machine, so a gate the
      # runtime enforces is a gate that a human pressing "merge" walks straight through. Projected
      # as protection, it binds every actor.
      #
      # `CI / *` and not the exact contexts: Gitea's Actions contexts are
      # `<workflow name> / <job> (<trigger>)`, so a commit carries BOTH `(push)` and
      # `(pull_request)`. The glob covers both and survives a project renaming its JOB — which the
      # shipped workflow explicitly invites ("chaque projet le RÉÉCRIT quand il sait ce qu'il est").
      # What it does NOT survive is a project renaming the WORKFLOW away from `CI`; that is the
      # coupling this leaves, deliberately, because the alternative (`*`) would require every
      # status any tool ever posts on the commit.
      enable_status_check: true,
      status_check_contexts: main_status_check_contexts()
    }

    case Repo.repo_mod(opts).protect_branch(repo, rule, Repo.fc_opts(opts)) do
      {:ok, outcome} -> announce_protection(repo, rule, outcome)
      {:error, reason} -> {:error, {:protect_main, reason}}
    end
  end

  @doc false
  @spec announce_protection(String.t(), term(), atom()) :: :ok
  def announce_protection(_repo, _rule, :unchanged), do: :ok

  def announce_protection(repo, rule, outcome) when outcome in [:created, :updated] do
    Logger.info(
      "ProjectOnboard: #{repo} main-protection #{outcome} " <>
        "(approvals=#{rule.required_approvals}, direct push refused)"
    )

    :ok
  end

  @doc false
  @spec clone_main(String.t(), String.t()) :: :ok | {:error, term()}
  def clone_main(url, proj_dir) do
    File.mkdir_p!(Path.dirname(proj_dir))
    GitOps.run(["clone", "--branch", "main", url, proj_dir], auth: true)
  end

  @doc false
  @spec publish_face(String.t(), String.t()) :: :ok | {:error, term()}
  def publish_face(dir, branch), do: push(dir, branch, true)

  # STANDALONE, not a linked worktree, and this is the reason both non-code faces are built this
  # way: `git worktree add` keeps the gitdir under the PARENT repository, so a face checked out
  # that way is uncommittable from any context that has the parent read-only — which is every pod
  # mounting `/home/projects` RO, and the architect itself. A standalone clone owns its `.git`.
  @doc false
  @spec init_face(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def init_face(dir, url, branch) do
    File.mkdir_p!(Path.dirname(dir))

    with :ok <- GitOps.run(["init", "-q", "-b", branch, dir], auth: false) do
      GitOps.run(["-C", dir, "remote", "add", "origin", url], auth: false)
    end
  end

  # Clone the face if the forge already carries the branch, otherwise build and publish it. Same
  # shape for both writer faces: every per-face input travels in ONE map (branch, template subtree,
  # host mode), so a third face costs a call site and no new logic.
  #
  # ⚠ SITE 3 SUR 3 — ET C'EST LUI QUI ECRIT. Sur une forge illisible, l'ancien `false` envoyait dans
  # le `else` : init + scaffold + **publication** d'une branche qui existe peut-etre deja, donc une
  # face distante ECRASEE sur un simple timeout. L'inverse (traiter l'erreur comme « existe ») ferait
  # cloner une branche peut-etre absente : moins destructeur, mais toujours une decision prise sans
  # savoir. On ne devine pas : on REFUSE, et l'import s'arrete avec la raison — l'appelant garde son
  # « repo untouched, a clean retry is possible ».
  #
  # Il rend `:cloned` ou `:published` et non `:ok`, parce que c'est la SEULE difference qui compte
  # pour defaire : `:published` est une branche que CETTE tentative a mise sur la forge, `:cloned`
  # une branche qui appartenait deja au depot. Confondre les deux, c'est soit laisser un residu,
  # soit supprimer le travail de quelqu'un d'autre.
  @doc false
  @spec ensure_face(String.t(), String.t(), map(), String.t(), keyword()) ::
          {:ok, :cloned | :published} | {:error, term()}
  def ensure_face(full_name, url, face, name, opts) do
    %{dir: dir, branch: branch, template: template, mode: mode} = face

    case Repo.repo_mod(opts).branch_exists?(full_name, branch, Repo.fc_opts(opts)) do
      {:error, reason} ->
        {:error, {:branch_unreadable, branch, reason}}

      {:ok, true} ->
        File.mkdir_p!(Path.dirname(dir))

        with :ok <- GitOps.run(["clone", "--branch", branch, url, dir], auth: true),
             :ok <- chmod_face(dir, mode) do
          {:ok, :cloned}
        end

      {:ok, false} ->
        with :ok <- init_face(dir, url, branch),
             :ok <- chmod_face(dir, mode),
             :ok <- Scaffold.face(dir, template, name, opts),
             :ok <- commit(dir, "chore(import): init #{branch}"),
             :ok <- publish_face(dir, branch) do
          {:ok, :published}
        end
    end
  end

  # NOMME L'ECHEC. Un `{:error, :eperm}` nu remonterait jusqu'a l'appelant sans dire de quel
  # repertoire il parle, dans un `with` qui en enchaine cinq.
  @doc false
  @spec chmod_face(String.t(), non_neg_integer()) :: :ok | {:error, term()}
  def chmod_face(dir, mode) do
    case File.chmod(dir, mode) do
      :ok -> :ok
      {:error, reason} -> {:error, {:face_mode_failed, dir, mode, reason}}
    end
  end

  # The three host roots of a project, resolved once per entry point. Named rather than threaded as
  # three positional paths: a face is added by extending this map and its template, not by widening
  # every signature between here and the git calls.
  @doc false
  @spec face_dirs(String.t(), keyword()) :: %{
          code: String.t(),
          workshop: String.t(),
          ops: String.t()
        }
  def face_dirs(name, opts) do
    %{
      code: Path.join(Keyword.get(opts, :code_root, @code_root), name),
      workshop: Path.join(Keyword.get(opts, :workshop_root, @workshop_root), name),
      ops: Path.join(Keyword.get(opts, :ops_root, @ops_root), name)
    }
  end

  @doc false
  @spec commit(String.t(), String.t()) :: :ok | {:error, term()}
  def commit(dir, message) do
    with :ok <- GitOps.run(["-C", dir, "add", "-A"], auth: false) do
      GitOps.run(["-C", dir, "commit", "-m", message], auth: false, author: onboard_author())
    end
  end

  @doc false
  @spec push(String.t(), String.t(), boolean()) :: :ok | {:error, term()}
  def push(dir, branch, set_upstream?) do
    args =
      ["-C", dir, "push"] ++
        if(set_upstream?, do: ["-u"], else: []) ++ ["origin", branch]

    GitOps.run(args, auth: true)
  end
end
