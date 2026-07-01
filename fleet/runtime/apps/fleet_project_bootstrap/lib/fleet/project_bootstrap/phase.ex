# `Fleet.CapProfile` garantit des clés STRING (normalisation à `to_struct`) →
# `Phase.Clone` accède `cap_profile.spec["..."]` directement, sans accesseur
# tolérant atom|string ni double-lookup défensif (le profil porte déjà la
# forme canonique, inutile de la re-vérifier ici).
defmodule Fleet.ProjectBootstrap.Phase do
  @moduledoc """
  `Phase.Clone` — la seule phase CÂBLÉE en prod du bootstrap de pod. Fonctions pures
  (aucun process : File / Path / git). Erreurs typées (codes de sortie distincts).
  Câblée DIRECTEMENT par `Fleet.Spawner.Pod` (`maybe_bootstrap_project_workspace` →
  `clone_or_skip`/`clone_work_doc`, et `reset_in_place` au re-brief slot-freeze).
  Accès cap-profile : clés STRING directes (`cap_profile.spec["..."]`) —
  `Fleet.CapProfile` garantit la forme à la production.

  (L'orchestrateur `prepare/3` et les 4 phases non-Clone — Allocate / InitMimic /
  BindCredentials / PrepareMountBinds — ont été RETIRÉS : chemin mort jamais câblé en
  prod, les concerns correspondants sont assurés ailleurs — CLAUDE.md par `do_project`
  côté pod.ex, mounts/creds par `bwrap_launch.sh`.)
  """

  defmodule Clone do
    @moduledoc """
    Phase 2 — CLONE branch feature OU skip (pod permanent / pas de repo).
    `git clone --reference <mirror bare local>` (objects locaux + fetch incrémental, pas de
    network par pod) si `spec.project.repo_path`, sinon workspace = répertoire vide (branch nil).
    """
    @spec clone_or_skip(Path.t(), Fleet.CapProfile.t(), keyword()) ::
            {:ok, Path.t(), String.t() | nil} | {:error, term()}
    def clone_or_skip(pod_dir, %Fleet.CapProfile{spec: spec}, opts) do
      project = spec["project"] || %{}

      case project["repo_path"] do
        nil ->
          ws = Path.join(pod_dir, "workspace")

          case File.mkdir_p(ws) do
            :ok -> {:ok, ws, nil}
            {:error, r} -> {:error, {:clone_failed, r}}
          end

        repo_url ->
          # `fleet_project_bootstrap` ne peut PAS dépendre de `fleet_spawner` (cycle compile), donc
          # `"workspace"` est ré-encodé ici — il DOIT rester en sync avec
          # `Fleet.Spawner.@pod_workspace_subdir` (autorité de la convention). Ce module est le
          # PRODUCTEUR (il crée et retourne le workspace) ; Pod le RECOMPUTE via pod_workspace_path/1.
          ws = Path.join(pod_dir, "workspace")

          # Idempotence du re-dispatch déterministe : un pod prédécesseur MORT (timeout/crash) laisse son
          # workspace sur disque ; comme le pod_id est déterministe (`<repo-slug>-issue-N-role`), le
          # re-dispatch retombe sur le MÊME pod_dir → `git clone` refuserait (« destination already exists
          # and is not an empty directory ») → wedge PERMANENT du ticket (un pod qui timeout boucle sinon à
          # l'infini sur clone_failed). Le pod POSSÈDE son pod_dir (garde spawn = 1 pod/pod_id) → un `ws`
          # résiduel ne peut venir que d'un prédécesseur mort → clean slate (le `base_sha` est ré-épinglé
          # juste après, un clone frais est toujours correct).
          _ = File.rm_rf(ws)

          ref = project["reference_repo_path"]
          base = project["base_branch"] || "main"

          # Monde propre : branche = `feature/<slug>` SANS le pod_id (l'agent ne doit pas relire son
          # pod_id dans sa propre branche — containment). Le slug vient du dispatcher (titre du ticket
          # sanitizé) ; défaut `work`. Le slug ne porte aucun préfixe `pod-`/`pod_` (la branche ne
          # divulgue pas l'identité du pod).
          slug = Keyword.get(opts, :slug, "work")
          feature = "feature/#{slug}"
          ref_args = if ref, do: ["--reference", ref], else: []

          # La deadline du clone RÉSEAU est calibrable par l'appelant (`:git_timeout_ms`), défaut = celui
          # du wrapper (30s). Le spawner peut la resserrer ; les tests l'utilisent pour prouver le bornage
          # (clone vers une URL qui pend → tué dans le délai, pas de pod zombie).
          git_opts = Keyword.take(opts, [:git_timeout_ms]) |> rename_timeout_key()

          # Clone/checkout BORNÉS par construction via `Fleet.Credentials.Shell.git/2` (Task.async +
          # yield(timeout) || brutal_kill, `GIT_TERMINAL_PROMPT=0` posé par `git_env/0`). Un `git` non
          # borné figerait le `Fleet.Spawner.Pod` (GenServer) si le clone réseau hung — ou si le git
          # prompte faute de credential, sans TTY → pod zombie / ticket wedgé. Le wrapper tue le git
          # enfant si la deadline expire et rend une erreur typée → le pod ne reste pas figé. `Shell.git/2`
          # injecte `git_env/0` (anti-prompt + auth forge).
          with {:ok, {_, 0}} <-
                 Fleet.Credentials.Shell.git(
                   ["clone"] ++ ref_args ++ ["--branch", base, repo_url, ws],
                   git_opts
                 ),
               # Si le rail forge-driven a PINNÉ une base_sha (ls-remote hors-pod), on épingle HEAD dessus
               # AVANT la feature-branch. Élimine la fenêtre « le pod clone une base que le rail n'a pas
               # capturée » (course same-role) : `base..HEAD` ne contiendra QUE les commits du pod.
               # Axiome posé AU boundary clone (pas vérifié « observable post-hoc »).
               {:ok, {_, 0}} <- pin_base_sha(ws, project["base_sha"]),
               # `checkout -b` est local (pas réseau, ne prompte pas) mais passe AUSSI par le wrapper
               # borné : invariant = aucun `System.cmd git` nu sur ce chemin (pas de git non borné
               # possible). Env bare (pas d'auth/réseau).
               {:ok, {_, 0}} <-
                 Fleet.Credentials.Shell.git(["-C", ws, "checkout", "-b", feature], env: []) do
            {:ok, ws, feature}
          else
            {:ok, {out, code}} -> {:error, {:clone_failed, {code, String.slice(out, 0, 500)}}}
            {:error, {:timeout, ms}} -> {:error, {:clone_failed, {:git_timeout, ms}}}
            {:error, {:exit, reason}} -> {:error, {:clone_failed, {:git_exit, reason}}}
          end
      end
    end

    # Traduit l'opt PUBLIC `:git_timeout_ms` (vocabulaire bootstrap) en `:timeout_ms` (vocabulaire
    # `Shell.git/2`). Absent → `[]` (le wrapper applique son défaut 30s). Garde la frontière du wrapper
    # honnête (un appelant ne peut pas, par mégarde, passer `:env`/`:cd` arbitraires au clone réseau).
    @doc """
    Reset IN-PLACE du workspace d'un pod RESIDENT (pipe slot-freeze) — PAS de rm_rf. Le `ws` est
    bind-monte dans le sandbox bwrap VIVANT du pipe : supprimer le dir casserait le mount (l'agent se
    retrouve dans un cwd deleted) + echouerait. On nettoie l'etat git du ticket PRECEDENT SUR PLACE :
    reset --hard sur le `base_sha` du NOUVEAU ticket (`pin_base_sha` reutilise, gere le fetch si la base
    a avance) + `clean -fdx` (vire l'untracked, ex. un fichier non committe) + `checkout -B feature/<slug>`
    (recree la branche de travail PROPRE depuis la base — `-B` force car la branche existe deja). Le `ws`
    DOIT exister (clone du spawn, jamais rm_rf en pipe) ; `base_sha` est REQUIS (le dispatcher l'epingle
    au re-brief). Retour homogene avec clone_or_skip : `{:ok, ws, feature}` | `{:error, {:reset_failed, _}}`.
    """
    @spec reset_in_place(Path.t(), Fleet.CapProfile.t(), keyword()) ::
            {:ok, Path.t(), String.t()} | {:error, term()}
    def reset_in_place(pod_dir, %Fleet.CapProfile{spec: spec}, opts \\ []) do
      project = spec["project"] || %{}
      ws = Path.join(pod_dir, "workspace")
      slug = Keyword.get(opts, :slug, "work")
      feature = "feature/#{slug}"

      case project["base_sha"] do
        sha when is_binary(sha) and sha != "" ->
          # pin_base_sha REUTILISE (reset --hard sha + fetch cible en fallback si la base a avance).
          # clean + checkout bornes via Shell.git (aucun `System.cmd git` nu ; env bare, local).
          with {:ok, {_, 0}} <- pin_base_sha(ws, sha),
               {:ok, {_, 0}} <- Fleet.Credentials.Shell.git(["-C", ws, "clean", "-fdx"], env: []),
               {:ok, {_, 0}} <-
                 Fleet.Credentials.Shell.git(["-C", ws, "checkout", "-B", feature], env: []) do
            {:ok, ws, feature}
          else
            {:ok, {out, code}} -> {:error, {:reset_failed, {code, String.slice(out, 0, 500)}}}
            {:error, {:timeout, ms}} -> {:error, {:reset_failed, {:git_timeout, ms}}}
            {:error, {:exit, reason}} -> {:error, {:reset_failed, {:git_exit, reason}}}
          end

        _ ->
          # base_sha absent = bug appelant (le dispatcher DOIT l'epingler au re-brief) → fail-loud
          # plutot qu'un reset sur une base indefinie (qui garderait l'etat du ticket precedent).
          {:error, {:reset_failed, :no_base_sha}}
      end
    end

    # Traduit l'opt PUBLIC `:git_timeout_ms` (vocabulaire bootstrap) en `:timeout_ms` (vocabulaire
    # `Shell.git/2`). Absent → `[]` (le wrapper applique son défaut 30s). Garde la frontière du wrapper
    # honnête (un appelant ne peut pas, par mégarde, passer `:env`/`:cd` arbitraires au clone réseau).
    defp rename_timeout_key([]), do: []
    defp rename_timeout_key(git_timeout_ms: ms), do: [timeout_ms: ms]

    # Épingle HEAD du workspace sur `sha` (capturé hors-pod par le rail forge-driven). Le clone `--branch base`
    # contient déjà `sha` dans le cas nominal (sha = tip) et fast-forward (sha = ancêtre) → `reset
    # --hard` local suffit. Cas pathologique (force-push remote a effacé `sha`) → `fetch` ciblé puis
    # reset. Le `fetch` est RÉSEAU (peut hung/prompter) → BORNÉ via `Shell.git/2` (le `reset` local
    # l'est aussi, pour ne laisser aucun `System.cmd git` nu). Retour homogène avec `Shell.git/2`
    # (`{:ok, {out, code}}` | `{:error, {:timeout|:exit, _}}`), consommé par le `with` de
    # `clone_or_skip`. nil/"" = no-op succès.
    defp pin_base_sha(_ws, sha) when sha in [nil, ""], do: {:ok, {"", 0}}

    defp pin_base_sha(ws, sha) when is_binary(sha) do
      case Fleet.Credentials.Shell.git(["-C", ws, "reset", "--hard", sha], env: []) do
        {:ok, {_, 0}} = ok ->
          ok

        _ ->
          # Le `reset` local a échoué (`sha` absent localement) → fetch RÉSEAU ciblé (auth forge + borne
          # anti-prompt via `git_env/0`), puis re-reset local. Échec du fetch (incl. timeout/exit) →
          # remonté tel quel au `with` → `{:clone_failed, ...}`.
          case Fleet.Credentials.Shell.git(["-C", ws, "fetch", "origin", sha]) do
            {:ok, {_, 0}} ->
              Fleet.Credentials.Shell.git(["-C", ws, "reset", "--hard", sha], env: [])

            other ->
              other
          end
      end
    end

    @doc """
    Doc-mount — clone la branche DOC du projet (`spec.project.work_branch`, orpheline `work/ops` par
    convention LCARS) dans `<pod_dir>/work` : la doc sur quoi l'agent s'appuie pour coder (plans,
    backlog, conventions). À côté de la branche code (`workspace`).

    - `work_branch` nil/absent OU pas de `repo_path` → `{:ok, nil}` (skip : projet sans branche doc).
    - déclarée mais clone échoué → `{:error, ...}` FAIL-LOUD : un cap-profile qui déclare une branche
      doc inexistante = bug de config, pas un pod silencieusement amputé de sa doc.
    """
    @spec clone_work_doc(Path.t(), Fleet.CapProfile.t()) ::
            {:ok, Path.t() | nil} | {:error, term()}
    def clone_work_doc(pod_dir, %Fleet.CapProfile{spec: spec}) do
      project = spec["project"] || %{}
      work_branch = project["work_branch"]
      repo_url = project["repo_path"]

      if is_nil(work_branch) or is_nil(repo_url) do
        {:ok, nil}
      else
        doc = Path.join(pod_dir, "work")
        ref = project["reference_repo_path"]
        ref_args = if ref, do: ["--reference", ref], else: []

        # PARITÉ avec `clone_or_skip` (même `rm_rf` du résidu) : un pod prédécesseur MORT laisse son
        # `work/` sur disque ; le pod_id étant déterministe, le re-dispatch retombe sur le même
        # `pod_dir` → `git clone` refuserait (« destination already exists and is not an empty
        # directory ») → même wedge permanent que le workspace. Clean slate : le `work/` résiduel ne
        # peut venir que d'un prédécesseur mort (le pod possède son pod_dir) → un re-clone frais est
        # toujours correct.
        _ = File.rm_rf(doc)

        # --single-branch : la branche doc est orpheline ⇒ inutile de fetch le reste de l'historique.
        # Clone RÉSEAU BORNÉ via `Shell.git/2` (anti-prompt + auth forge via `git_env/0`, tué dans la
        # deadline si hung → pas de pod figé sur le clone de la doc).
        case Fleet.Credentials.Shell.git(
               ["clone"] ++
                 ref_args ++ ["--branch", work_branch, "--single-branch", repo_url, doc]
             ) do
          {:ok, {_, 0}} ->
            {:ok, doc}

          {:ok, {out, code}} ->
            {:error, {:work_doc_clone_failed, {work_branch, code, String.slice(out, 0, 500)}}}

          {:error, {:timeout, ms}} ->
            {:error, {:work_doc_clone_failed, {work_branch, :git_timeout, ms}}}

          {:error, {:exit, reason}} ->
            {:error, {:work_doc_clone_failed, {work_branch, :git_exit, reason}}}
        end
      end
    end

    # Pas de helper `forge_auth_args/0` local (ni dup de `Fleet.Pipeline.Git`, malgré le cycle compile
    # pipeline⇄bootstrap) : l'auth forge a une source unique `Fleet.Credentials.ForgeAuth.git_env/0`
    # (fleet_credentials est en-dessous des deux apps → pas de cycle), token via env hors argv.

    # Pas de `set_git_identity/2` : poser l'identité du rôle via `git config` dans le `.git/config` du
    # workspace serait MUTABLE — le pod pourrait l'écraser (`git config user.email …`) → identité
    # falsifiable. L'identité est posée en env au lancement (bwrap_launch.sh : GIT_AUTHOR_*/GIT_COMMITTER_*
    # = LCARS-<role> / <role>@lcars.local + GIT_CONFIG_GLOBAL=/dev/null), défaut coopératif déterministe
    # que le pod ne peut pas surcharger. La garantie vit côté monde :
    # `Fleet.Pipeline.DeliverableGate.check_identity/3` rejette au push tout commit hors identité
    # autorisée (le pod ne PEUT PAS pousser un livrable usurpé).
  end
end
