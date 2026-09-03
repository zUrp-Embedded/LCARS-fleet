defmodule Fleet.Project.Onboard.Import do
  @moduledoc """
  Faire entrer sur la boite ce qui vient d'AILLEURS : une forge externe (`import_external/3`) ou le
  magasin d'un catalogue (`import_deposit/3`), plus l'inventaire de ce qu'un humain peut deposer
  (`deposit_candidates/2`).

  Ces verbes CREENT le depot d'arrivee, donc leur compensation le supprime en entier — c'est ce qui
  les separe d'`import/2`, dont la cible preexiste et qui ne peut defaire que ce qu'il a pousse.
  """

  alias Fleet.Credentials.Shell
  alias Fleet.Project.Onboard
  alias Fleet.Project.Onboard.Faces
  alias Fleet.Project.Onboard.Repo

  require Logger

  # LE TROISIEME REFUS, et c'est celui qui empeche le mensonge silencieux. L'org d'un projet EST le
  # nom de son catalogue, et ce lien est fixe pour sa vie : importer `web/vitrine` sur une boite qui
  # n'a pas le catalogue `web` ne doit PAS retomber sur le catalogue local. Le projet tournerait avec
  # les roles, les cartes et les SP d'un autre metier, sans que rien ne le dise — c'est exactement
  # l'etat que le lien fixe existe pour interdire.
  #
  # Le refus NOMME le catalogue manquant et le geste qui le pose, parce qu'un refus qui ne dit pas
  # quoi faire ne se distingue pas d'une panne.
  @doc """
  DEPOT : enrole un depot depuis l'espace PERSONNEL d'un humain vers l'org du catalogue choisi.

  C'est la troisieme porte d'entree, et elle existe parce que les deux autres refusent ce cas par
  construction, chacune pour sa bonne raison :

    * `import/2` ne prend que des depots DEJA dans une org de catalogue (`require_catalogue_installed`)
      et ne filtre donc rien — il n'a pas a le faire ;
    * `import_external/3` exige `https` + un hote de son allowlist, et notre forge est en `http` :
      elle serait refusee sur le SCHEMA. Cette garde borne « depuis quel hote ETRANGER on clone »,
      et un depot personnel sur notre forge n'est pas un hote etranger — c'est une PROVENANCE
      etrangere. Deux notions, deux gardes.

  La frontiere d'adoption n'est donc pas « notre forge / forge externe » mais **« dans une org de
  catalogue / hors org »** : tout ce qui vient d'un espace personnel passe le gate, meme depose par
  un humain de confiance sur notre propre forge. Le transport ne change pas la provenance.

  Le depot source n'est PAS consomme : il reste chez son proprietaire, c'est sa copie.
  """
  @spec import_deposit(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def import_deposit(source, catalogue, opts \\ [])
      when is_binary(source) and is_binary(catalogue) do
    with {:ok, owner, src_name} <- split_repo(source),
         :ok <- refute_source_in_org(owner, source),
         :ok <- require_destination_catalogue(catalogue),
         # LAST of the admission checks: the only one that costs a forge read. The three above
         # answer from the catalogue alone, so a malformed name or an unknown destination is
         # refused without touching the network.
         :ok <- require_public_source(source, opts) do
      name = Keyword.get(opts, :name, src_name)
      full_name = "#{catalogue}/#{name}"
      dirs = Faces.face_dirs(name, opts)

      with :ok <- Onboard.admit(catalogue, name, opts),
           :ok <- Repo.ensure_catalogue_org_on_forge(catalogue, opts),
           :ok <- require_machine_absent(full_name, dirs),
           :ok <- Repo.require_forge_absent(full_name, opts),
           {:ok, source_url} <- Repo.repo_url(source, opts) do
        scratch = external_scratch_dir(name)

        try do
          with :ok <- clone_deposit(source_url, scratch, opts),
               :ok <- adoption_gate(scratch),
               :ok <- normalize_default_branch(scratch),
               {:ok, forge_url} <- Repo.repo_url(full_name, opts),
               {:ok, full_name} <- Repo.create_empty_repo(name, catalogue, opts) do
            case finish_external(
                   full_name,
                   forge_url,
                   scratch,
                   dirs,
                   name,
                   Keyword.put(opts, :source_host, "depot:#{owner}")
                 ) do
              {:ok, result} ->
                {:ok, Map.put(result, :from, source)}

              {:error, reason} = err ->
                compensate_external(full_name, dirs, reason, opts)
                err
            end
          end
        after
          _ = File.rm_rf(scratch)
        end
      end
    end
  end

  @doc """
  A human's DEPOSIT CANDIDATES: the repos in their personal space that no catalogue org already
  carries under the same name.

  THE LOCATION IS THE STATE: a repo in a personal space is a candidate, a repo in a catalogue org is
  enrolled. So there is no marker, no label and no registry to keep — "is this project in LCARS?"
  is answered by an `ls` on the forge. Multiple catalogues REINFORCE that rather than weaken it:
  whatever the number of orgs, *outside every org* stays one unambiguous location.

  The filter is by NAME because the source repo is NOT consumed — importing takes a copy and leaves
  the original with its owner — so without it every pass would propose the same repo again.

  Each candidate carries whether its NAME is admissible, and the rule when it is not. The name is
  checked here rather than at import alone because the import is too late: the human has already
  pushed everything by then, and learning the rule at that point is learning it after paying for
  it. The listing is the first moment the fleet can say it.
  """
  @spec deposit_candidates(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def deposit_candidates(human, opts \\ []) when is_binary(human) do
    repo = Repo.repo_mod(opts)
    fc = Repo.fc_opts(opts)

    with {:ok, mine} <- repo.list_user_repos(human, fc),
         {:ok, enrolled} <- enrolled_names(repo, fc) do
      {:ok,
       mine
       |> Enum.reject(&(Fleet.Layout.project_name(&1) in enrolled))
       |> Enum.sort()
       |> Enum.map(&describe_candidate/1)}
    end
  end

  # The name rule, rendered rather than merely applied: an agent that must PRESENT a candidate to a
  # human needs to say what is wrong with it, and `{:error, {:invalid_name, _}}` at import time
  # says it to the wrong reader at the wrong moment.
  defp describe_candidate(full_name) do
    name = Fleet.Layout.project_name(full_name)

    case Onboard.validate_name(name) do
      :ok ->
        %{"source" => full_name, "name" => name, "admissible" => true}

      {:error, {:invalid_name, _}} ->
        %{
          "source" => full_name,
          "name" => name,
          "admissible" => false,
          "reason" =>
            "le nom doit être en kebab-case minuscule (`[a-z0-9]`, tirets internes) — " <>
              "renomme le dépôt sur la forge, ou donne-lui son nom de destination à l'import"
        }
    end
  end

  # The names already carried by an INSTALLED catalogue org. Fail-loud: an unreachable org would make
  # the candidate list too WIDE, i.e. offer to import what is already in.
  defp enrolled_names(repo, fc) do
    Enum.reduce_while(Onboard.installed_orgs(), {:ok, MapSet.new()}, fn org, {:ok, acc} ->
      case repo.list_org_repos(org, fc) do
        {:ok, names} ->
          {:cont, {:ok, Enum.into(Enum.map(names, &Fleet.Layout.project_name/1), acc)}}

        {:error, reason} ->
          {:halt, {:error, {:enrolled_scan_failed, org, reason}}}
      end
    end)
  end

  defp split_repo(full_name) do
    case String.split(full_name, "/") do
      [owner, name] when owner != "" and name != "" -> {:ok, owner, name}
      _ -> {:error, {:not_a_repo_name, full_name}}
    end
  end

  # Un depot deja dans une org de catalogue n'est pas un DEPOT : c'est un projet enrolle. Le
  # reprendre par cette porte le clonerait puis le recreerait ailleurs, alors que les verbes justes
  # existent — `import/2` pour l'adopter localement, `migrate/3` pour le changer de catalogue.
  defp refute_source_in_org(owner, source) do
    if owner in Onboard.installed_orgs(),
      do: {:error, {:source_already_enrolled, source, owner}},
      else: :ok
  end

  defp require_destination_catalogue(catalogue), do: Onboard.require_installed(catalogue)

  # A PRIVATE deposit is refused, and it is refused HERE rather than left to the clone.
  #
  # There is no config lever to force public repos on this forge: `[repository] DEFAULT_PRIVATE`
  # does NOT exist in the Gitea we run (measured on the image's own binary, with a witness — the
  # neighbouring `DEFAULT_SHOW_FULL_NAME` is there, this one is not). So a private repo stays
  # creatable, and the only honest place to stop it is the door.
  #
  # Asking the forge is not the same as watching the clone fail: this runtime's git carries the
  # system token, so a private source would clone WITHOUT error and its content would land in a
  # public org repo. A visibility change nobody asked for is worse than a refusal, and it is
  # invisible exactly when it happens.
  defp require_public_source(source, opts) do
    case Repo.repo_mod(opts).private?(source, Repo.fc_opts(opts)) do
      {:ok, false} -> :ok
      {:ok, true} -> {:error, {:deposit_not_public, source}}
      {:error, reason} -> {:error, {:deposit_visibility_unreadable, source, reason}}
    end
  end

  # Clones the deposit. The visibility question is settled BEFORE this, by `require_public_source/2`
  # — not by letting the clone fail, because this call carries the system token and a private repo
  # would clone just fine, copying private content into a public org repo with nothing said.
  defp clone_deposit(url, scratch, opts) do
    timeout = Keyword.get(opts, :clone_timeout_ms, 120_000)

    case Shell.git(["clone", "--no-recurse-submodules", url, scratch],
           timeout_ms: timeout
         ) do
      {:ok, {_, 0}} ->
        :ok

      {:ok, {out, code}} ->
        {:error, {:deposit_clone_failed, {code, String.slice(out, 0, 500)}}}

      {:error, reason} ->
        {:error, {:deposit_clone_failed, reason}}
    end
  end

  # External forges this verb repatriates from (BL-6-31, user perimeter). Everything else is a
  # named refusal — extending the list is a deliberate one-line decision here.
  @external_hosts ~w(github.com gitlab.com)

  @doc """
  IMPORTS a repo from an EXTERNAL forge (GitHub/GitLab — BL-6-31): repatriate → adoption gate →
  create in the org → push → the existing local import leg. One-way: the external origin is
  LEFT BEHIND (origin is re-pointed at OUR forge — an import, never a mirror).

  The sequence (plan 6-16/6-31 v2.1, orchestration NEW, primitives reused):
    1. URL gate — https + host ∈ #{inspect(@external_hosts)}; anything else refuses
       `{:unsupported_forge, _}`.
    2. System clone into a per-gesture SCRATCH (`--no-recurse-submodules` — a hostile submodule
       is never repatriated silently), cleaned on EVERY exit. Auth is the WIRED git credential
       helper (gh/glab Tier 1, or the operator's own helper Tier 2), reached via the inherited HOME
       under `GIT_TERMINAL_PROMPT=0` — the same tiered model as publish, no external token handled.
       Public repos clone tokenless; a private one needs gh/glab authed (or a wired helper).
    3. ADOPTION GATE (the parking-lot USB, BL-6-16): a non-empty `.claude/` tree is refused EN
       BLOC (`{:foreign_claude_dir, _}` — we do not adopt someone else's hooks; org repos
       re-enter via `import/2`, never through this verb), and every `CLAUDE.md` must pass
       `Fleet.ReceptionFilter` (`{:hostile_material, label, path}` otherwise). Nothing reaches
       the org on a refusal — the operator expurges at the SOURCE and retries.
    4. Default branch → `main`, THREE cases: already main → no-op; main absent → rename;
       default ≠ main while a remote `main` EXISTS → `{:branch_collision, _}` (half-migrated
       repos are common; we never guess which is the real one).
    5. Empty org repo + protocol labels + declaration committed IN the scratch BEFORE the push
       (the push must CARRY .lcars.json or every later jury read falls back in silence) →
       push main (full history) → the local `finish_import` leg (clone from OUR forge,
       ops, protection — its `lock_main` reads the now-present local declaration).

  Refusals before any effect: dirs already on machine (`{:already_on_machine, _}` — that
  project wants `open`/`import`), forge repo existing (`{:repo_already_exists, _}`).
  Compensation: forge repo deleted DIRECT (the 6-32 lesson — an empty just-created repo probes
  absent through delete_forge and would leak) + both local dirs; the scratch dies in `after`.
  """
  @spec import_external(String.t(), String.t(), keyword()) ::
          {:ok, Onboard.result()} | {:error, term()}
  def import_external(url, name, opts \\ []) when is_binary(url) and is_binary(name) do
    dirs = Faces.face_dirs(name, opts)
    # Injection seam over the pure gate (tests drive file:// fixtures) — prod default enforces.
    url_gate = Keyword.get(opts, :url_gate, &default_external_url_gate/1)

    # L'ADMISSION COMMUNE D'ABORD, LES SPECIFICITES ENSUITE — uniformement sur les cinq verbes.
    with {:ok, org} <- Onboard.required_org(opts),
         :ok <- Onboard.admit(org, name, opts),
         full_name = "#{org}/#{name}",
         :ok <- url_gate.(url),
         :ok <- Repo.ensure_catalogue_org_on_forge(org, opts),
         :ok <- require_machine_absent(full_name, dirs),
         :ok <- Repo.require_forge_absent(full_name, opts) do
      scratch = external_scratch_dir(name)

      try do
        with :ok <- clone_external(url, scratch, opts),
             :ok <- adoption_gate(scratch),
             :ok <- normalize_default_branch(scratch),
             {:ok, forge_url} <- Repo.repo_url(full_name, opts),
             {:ok, full_name} <- Repo.create_empty_repo(name, org, opts) do
          source_host =
            case URI.parse(url).host do
              h when h in [nil, ""] -> "external"
              h -> h
            end

          case finish_external(
                 full_name,
                 forge_url,
                 scratch,
                 dirs,
                 name,
                 Keyword.put(opts, :source_host, source_host)
               ) do
            {:ok, result} ->
              {:ok, result}

            {:error, reason} = err ->
              compensate_external(full_name, dirs, reason, opts)
              err
          end
        end
      after
        _ = File.rm_rf(scratch)
      end
    end
  end

  # The compensable window — finish_adopt's proven order (declaration BEFORE push), then the
  # existing local import leg for what it does (clone from OUR forge brings .lcars.json
  # back down, so ITS lock_main reads the right jury).
  defp declaration_commit_message(opts) do
    door =
      case Keyword.get(opts, :source_host, "") do
        "depot:" <> _ -> "import-depot"
        _ -> "import-externe"
      end

    "chore(#{door}): déclaration de criticité (.lcars.json)"
  end

  defp finish_external(full_name, forge_url, scratch, dirs, name, opts) do
    with :ok <- Fleet.Forge.WriteSpacing.gap(opts),
         :ok <- Repo.seed_protocol_labels(full_name, opts),
         # The commit message names the ACTUAL door: this leg is shared by the external import and
         # the deposit, and a deposit whose history says "import-externe" tells the project's own
         # log something that did not happen.
         :ok <-
           Onboard.ensure_declaration(scratch, full_name, opts, declaration_commit_message(opts)),
         :ok <-
           Onboard.ensure_ci_workflows(
             scratch,
             name,
             Onboard.with_ci_stance(full_name, opts),
             "ci(import): rail CI du depot (.gitea/workflows)"
           ),
         :ok <- Faces.set_origin(scratch, forge_url),
         :ok <- Faces.push(scratch, "main", true),
         :ok <- Fleet.Forge.WriteSpacing.gap(opts),
         {:ok, result} <- Onboard.finish_import(full_name, dirs, name, opts) do
      Logger.info(
        "ProjectOnboard: #{full_name} imported from EXTERNAL " <>
          "#{Keyword.get(opts, :source_host, "external")} — history preserved, origin " <>
          "re-pointed at the org (the source URL is never logged: it may carry the operator token)"
      )

      {:ok, result}
    end
  end

  defp default_external_url_gate(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme != "https" -> {:error, {:unsupported_forge, {:scheme, uri.scheme}}}
      uri.host in @external_hosts -> :ok
      true -> {:error, {:unsupported_forge, uri.host}}
    end
  end

  defp require_machine_absent(full_name, dirs) do
    if Enum.any?([dirs.code, dirs.ops, dirs.workshop], &File.exists?/1),
      do: {:error, {:already_on_machine, full_name}},
      else: :ok
  end

  # Per-gesture unique scratch (two concurrent imports of the same name never share one; the
  # NAME collision itself is refused upstream by require_forge_absent). BEAM-side, outside any
  # pod sandbox. (NOT the card-revision scratch_dir/1 above — different lifecycle, per-gesture.)
  defp external_scratch_dir(name) do
    Path.join(
      System.tmp_dir!(),
      "lcars-import-#{name}-#{:erlang.unique_integer([:positive])}"
    )
  end

  defp clone_external(url, scratch, opts) do
    timeout = Keyword.get(opts, :clone_timeout_ms, 120_000)

    # Auth is the WIRED git credential helper — gh/glab (Tier 1) or the operator's own helper (Tier 2),
    # reached via the inherited HOME, the SAME tiered model as publish. No external token is read,
    # stored, or passed: LCARS_EXTERNAL_GIT_TOKEN is retired. Shell.git's default env is
    # ForgeAuth.git_env/0 — GIT_TERMINAL_PROMPT=0 (a missing helper fails LOUD, never hangs a headless
    # clone) plus the INTERNAL forge extraheader, scoped to the internal host and so inert for an
    # external clone (a private external repo needs gh/glab authed, or a wired helper — Tier 2).
    case Shell.git(
           ["clone", "--no-recurse-submodules", url, scratch],
           timeout_ms: timeout
         ) do
      {:ok, {_, 0}} ->
        :ok

      {:ok, {out, code}} ->
        {:error, {:external_clone_failed, {code, String.slice(out, 0, 500)}}}

      {:error, reason} ->
        {:error, {:external_clone_failed, reason}}
    end
  end

  # The parking-lot USB check (BL-6-16/6-31): instruction-tier material only — scanning the
  # whole code would drown in false positives (a README legitimately says "force-push").
  #
  # ⚠ DECLARED BLIND SPOT — `.gitmodules` IS NOT READ. This gate probes exactly two things,
  # `**/.claude` and `**/CLAUDE.md`, and a foreign repo can carry a `.gitmodules` pointing anywhere.
  # Nothing is fetched from it: `clone_external` passes `--no-recurse-submodules`, and the fleet
  # never runs `git submodule update` on an imported project — so the practical risk today is low.
  # This sentence exists because an unwritten limit makes a gate people lean on too hard, and a
  # perimeter nobody knows is exactly that. Widening the probe is a decision, not
  # a reflex; the honest minimum is to say what is not looked at, next to what is.
  defp adoption_gate(scratch) do
    case foreign_claude_dirs(scratch) do
      [] -> scan_claude_mds(scratch)
      dirs -> {:error, {:foreign_claude_dir, dirs}}
    end
  end

  defp foreign_claude_dirs(scratch) do
    scratch
    |> Path.join("**/.claude")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&(".git" in Path.split(Path.relative_to(&1, scratch))))
    |> Enum.filter(&File.dir?/1)
    |> Enum.map(&Path.relative_to(&1, scratch))
  end

  defp scan_claude_mds(scratch) do
    scratch
    |> Path.join("**/CLAUDE.md")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&(".git" in Path.split(Path.relative_to(&1, scratch))))
    |> Enum.reduce_while(:ok, fn path, :ok ->
      rel = Path.relative_to(path, scratch)

      case File.read(path) do
        {:ok, content} ->
          case Fleet.ReceptionFilter.scan(content) do
            :clean -> {:cont, :ok}
            {:match, label, _excerpt} -> {:halt, {:error, {:hostile_material, label, rel}}}
          end

        {:error, reason} ->
          # Unreadable instruction material in a fresh clone: refused, never waved through.
          {:halt, {:error, {:unreadable_material, rel, reason}}}
      end
    end)
  end

  # Three cases (plan F6): a half-migrated repo (default=master AND a remote main) is REFUSED —
  # we never guess which branch is the real one; the operator settles it at the source.
  defp normalize_default_branch(scratch) do
    with {:ok, {head_out, 0}} <-
           Shell.git(["-C", scratch, "symbolic-ref", "--short", "HEAD"],
             env: []
           ),
         {:ok, {remotes_out, 0}} <-
           Shell.git(
             ["-C", scratch, "branch", "-r", "--format=%(refname:short)"],
             env: []
           ) do
      head = String.trim(head_out)
      remote_main? = "origin/main" in String.split(remotes_out, "\n", trim: true)

      cond do
        head == "main" ->
          :ok

        remote_main? ->
          {:error, {:branch_collision, {head, "main"}}}

        true ->
          case Shell.git(["-C", scratch, "branch", "-m", head, "main"],
                 env: []
               ) do
            {:ok, {_, 0}} ->
              :ok

            {:ok, {out, code}} ->
              {:error, {:branch_rename_failed, {code, String.slice(out, 0, 300)}}}

            {:error, reason} ->
              {:error, {:branch_rename_failed, reason}}
          end
      end
    else
      other -> {:error, {:default_branch_unreadable, other}}
    end
  end

  # Same direct-primitive posture as compensate_adopt (the 6-32 lesson), plus both local dirs —
  # unlike adopt, EVERYTHING local here was created by this call.
  defp compensate_external(full_name, dirs, reason, opts) do
    forge =
      case Repo.repo_mod(opts).delete_repo(full_name, Repo.fc_opts(opts)) do
        :ok -> :deleted
        {:error, e} -> {:delete_failed, e}
      end

    Logger.warning(
      "ProjectOnboard: import_external #{full_name} FAILED (#{inspect(reason)}) — compensated: " <>
        "forge #{inspect(forge)}, project_dir #{inspect(Faces.compensate_dir(dirs.code))}, " <>
        "work_dir #{inspect(Faces.compensate_dir(dirs.ops))}, " <>
        "doc_dir #{inspect(Faces.compensate_dir(dirs.workshop))} (a clean retry is possible)"
    )
  end
end
