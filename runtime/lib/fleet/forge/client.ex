defmodule Fleet.Forge.Client do
  @moduledoc """
  The Gitea REST API client — the DOMAIN layer of the forge-state-machine (the forge IS the state
  machine). Carries the ops on issues/PRs (idempotent read/write), PR jury state, repo onboarding,
  and the credential→wire adapter `as_role/2`. It is the module injected by the `:forge_client`
  seam (StepDispatcher/Poller/MCP).

  Two layers live BELOW it, and a few of their functions are re-exported here because a seam
  names THIS module:

    * `Fleet.Forge.Client.Transport` — HTTP/config/encoding/pagination engine + system login.
      No knowledge of the forge protocol. This module `import`s it (`http_get`, `paginate`, …).
    * `Fleet.Forge.Protocol` — PURE vocabulary of the wire-protocol (feature-branches, comment
      markers, the parked title, result blocks, `system_authored?`), build+parse co-located. Callers
      call it DIRECTLY. Only `parse_feature_branch/1` is re-exported here (`defdelegate`) because
      `Fleet.MCP` reaches it through the `:forge_client` seam.

  ⚠ CROSS CONTRACT (`Fleet.MCP` seam): this module is the REAL (default) impl of the behaviour
  `Fleet.MCP.PodTools.Delegation.ForgeClient` (13 callbacks: `create_issue`, `add_label`,
  `repo_label_id`, `get_issue`, `list_pulls`, `list_open_issues`, `parse_feature_branch`,
  `pr_review_state`, `get_route`, `post_comment`, `close_issue`, `close_pr`,
  `merged_pr_of_issue`). It CANNOT be adopted as a `@behaviour`: `Fleet.Forge` does not depend on
  `Fleet.MCP` (MCP sits above it) and the compile reference would be a Boundary violation.
  Duck-typed impl — any evolution of these signatures MUST be mirrored onto the behaviour's
  `@callback`s (and vice versa); `Delegation.conforming/2` is the witness that holds it.

  ## Configuration

  Resolved at call time by `Transport.resolve_config/1` (see its moduledoc): `:base_url`, then
  ONE token source — `:token`, `:token_file`, or `:account` (asked of the authority service);
  none is a named refusal, never a fallback to a personal file — and `:req_options` passed to
  `Req`.

  ## Idempotence

  Write-ops are idempotent (skip if the target state is already reached). E.g. `add_label/4`:
  `GET issue labels` to short-circuit, else `POST issue/labels` by NAME (Gitea resolves repo+org
  server-side and dedups by name — no duplicate) with response VERIFICATION and repo-label self-heal;
  re-call on a label already present = `{:ok, :already_present}`, zero write round-trip.
  """

  require Logger

  alias Fleet.Forge.Client.CI
  alias Fleet.Forge.Client.Jury
  alias Fleet.Forge.Client.Labels
  alias Fleet.Forge.Client.Merge
  alias Fleet.Forge.Client.Repo
  alias Fleet.Forge.Client.Signing
  alias Fleet.Forge.Protocol, as: ForgeProtocol

  import Fleet.Forge.Client.Transport,
    only: [
      resolve_config: 1,
      http_get: 2,
      http_post: 3,
      http_patch: 3,
      http_delete: 2,
      http_delete_body: 3,
      paginate: 3,
      forge_bot_login: 2,
      login_of: 1
    ]

  import Fleet.Forge.Client.UrlSafe, only: [encode_repo: 1, encode_seg: 1]

  @spec parse_feature_branch(term()) :: {:ok, {integer(), String.t()}} | :error
  defdelegate parse_feature_branch(head), to: ForgeProtocol

  @spec branch_head(String.t(), String.t(), Keyword.t()) :: {:ok, String.t()} | {:error, term()}
  defdelegate branch_head(repo, branch, opts), to: Repo

  # ⚠ RE-EXPORTE PARCE QU'UN BEHAVIOUR NOMME CE MODULE-CI COMME SON DEFAUT, pas parce que la facade
  # voudrait grossir : une fonction sortie dans un sous-module sans etre reexposee ici fait mourir
  # tout appel qui passe par ce seam.
  #
  # Le trou est EN AMONT : rien ne verifie qu'une implementation PAR DEFAUT tient le contrat qui la
  # designe. C'est le temoin de conformite (`Delegation.conforming/2`) qui le ferme, pour tous les
  # seams a la fois.
  @spec put_file(String.t(), String.t(), String.t(), Keyword.t()) ::
          {:ok, term()} | {:error, term()}
  defdelegate put_file(repo, path, content, opts), to: Fleet.Forge.Client.Files

  # SON JUMEAU, ET IL TOMBE PLUS DUREMENT. `Client.Files` porte `get_file` ET `put_file`, et deux
  # appelants distincts passent par cette facade. Celui-ci est `probe.ex` —
  # `forge().get_file(repo, "CLAUDE.md", …)`, sur le chemin de `run_probe`, l'outil des juges.
  #
  # ⚠ LA DIFFERENCE DE MANIFESTATION EST TOUTE LA LECON. `put_file` passe par un behaviour, donc
  # `conforming/2` rend `{:seam_misconfigured, …, [put_file: 4]}` : un refus qui NOMME quoi
  # reparer. Le seam de `probe.ex` (`get_env(:lcars_fleet, :mcp_probe_forge_client, …)`) ne declare
  # aucun `@callback` — aucun garde n'a rien a verifier, et le juge recoit un
  # `UndefinedFunctionError` brut. Meme defaut, meme module, meme decoupage : seule la presence d'un
  # contrat change ce qu'en voit celui qui le subit.
  @spec get_file(String.t(), String.t(), Keyword.t()) ::
          {:ok, %{content: String.t(), sha: String.t()}} | {:error, term()}
  defdelegate get_file(repo, path, opts), to: Fleet.Forge.Client.Files

  @doc """
  Adds and verifies a label, returning `:already_present` without writing when applicable.

  Missing protocol labels are created at repository scope and retried; unverifiable success returns
  `{:error, {:label_not_added, label_name}}`.
  """
  @spec add_label(String.t(), integer(), String.t(), Keyword.t()) ::
          {:ok, :added | :already_present}
          | {:error, term()}
  def add_label(repo, issue_number, label_name, opts \\ [])
      when is_binary(repo) and is_integer(issue_number) and is_binary(label_name) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, current} <- Labels.get_issue_labels(config, repo, issue_number),
         current_names = Enum.map(current, & &1["name"]),
         false <- label_name in current_names && :already_present,
         :ok <- Labels.add_issue_label(config, repo, issue_number, label_name) do
      {:ok, :added}
    else
      :already_present -> {:ok, :already_present}
      {:error, _} = err -> err
    end
  end

  @doc """
  Lists all open issues visible to the optional forge-side `:assigned_by` scope.
  """
  @spec list_open_issues(String.t(), Keyword.t()) :: {:ok, [map()]} | {:error, term()}
  def list_open_issues(repo, opts \\ []) when is_binary(repo) do
    list_scoped_issues(repo, "issues", opts)
  end

  # `assigned_by` is honoured on `/issues` for BOTH types (Gitea 1.26.1), so the poller sees only
  # what the forge itself scoped — no client-side filtering of a wider list.
  defp list_scoped_issues(repo, type, opts) when type in ["issues", "pulls"] do
    state = Keyword.get(opts, :state, "open")

    with {:ok, config} <- resolve_config(opts) do
      paginate(
        config,
        "/repos/#{encode_repo(repo)}/issues",
        "state=#{state}&type=#{type}" <> assigned_by_qs(opts)
      )
    end
  end

  @doc false
  @spec assigned_by_qs(keyword()) :: String.t()
  def assigned_by_qs(opts) do
    case Keyword.get(opts, :assigned_by) do
      login when is_binary(login) and login != "" -> "&assigned_by=" <> URI.encode_www_form(login)
      _ -> ""
    end
  end

  @doc """
  Reads an issue by number, including state, labels, and assignees.
  """
  @spec get_issue(String.t(), integer(), Keyword.t()) :: {:ok, map()} | {:error, term()}
  def get_issue(repo, number, opts \\ []) when is_binary(repo) and is_integer(number) do
    with {:ok, config} <- resolve_config(opts) do
      http_get(config, "/repos/#{encode_repo(repo)}/issues/#{number}")
    end
  end

  @doc """
  Lists every issue comment oldest-first; the final element is therefore the true newest comment.
  """
  @spec list_comments(String.t(), integer(), Keyword.t()) :: {:ok, [map()]} | {:error, term()}
  def list_comments(repo, number, opts \\ []) when is_binary(repo) and is_integer(number) do
    with {:ok, config} <- resolve_config(opts) do
      paginate(config, "/repos/#{encode_repo(repo)}/issues/#{number}/comments", "")
    end
  end

  @doc """
  Replaces issue assignees with exactly `login`, returning `:already` when converged.
  """
  @spec set_assignee(String.t(), integer(), String.t(), Keyword.t()) ::
          {:ok, :set | :already} | {:error, term()}
  def set_assignee(repo, issue_number, login, opts \\ [])
      when is_binary(repo) and is_integer(issue_number) and is_binary(login) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, issue} <- http_get(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}") do
      current = Enum.map(Map.get(issue, "assignees") || [], & &1["login"])

      if current == [login] do
        {:ok, :already}
      else
        case http_patch(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}", %{
               assignees: [login]
             }) do
          {:ok, _} -> {:ok, :set}
          {:error, _} = err -> err
        end
      end
    end
  end

  @doc """
  Posts a comment, deduplicating `:dedup_signature` only against authenticated system comments.

  If the bot identity or comment history cannot be resolved, no existing marker is trusted and the
  comment is posted.
  """
  @spec post_comment(String.t(), integer(), String.t(), Keyword.t()) ::
          {:ok, :posted | :already} | {:error, term()}
  def post_comment(repo, issue_number, body, opts \\ [])
      when is_binary(body) do
    sig = Keyword.get(opts, :dedup_signature)

    with {:ok, config} <- resolve_config(opts) do
      if sig && Signing.signed_or_warn(config, repo, issue_number, sig, opts) do
        {:ok, :already}
      else
        case http_post(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}/comments", %{
               body: body
             }) do
          {:ok, _} -> {:ok, :posted}
          {:error, _} = err -> err
        end
      end
    end
  end

  @doc """
  Removes an attached label, returning `:already_absent` when converged.
  """
  @spec remove_label(String.t(), integer(), String.t(), Keyword.t()) ::
          {:ok, :removed | :already_absent} | {:error, term()}
  def remove_label(repo, issue_number, label_name, opts \\ [])
      when is_binary(label_name) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, current} <- Labels.get_issue_labels(config, repo, issue_number) do
      # Attached-label ids cover repository and organization labels.
      case Enum.find(current, &(&1["name"] == label_name)) do
        nil ->
          {:ok, :already_absent}

        %{"id" => id} ->
          case http_delete(
                 config,
                 "/repos/#{encode_repo(repo)}/issues/#{issue_number}/labels/#{id}"
               ) do
            {:ok, _} -> {:ok, :removed}
            {:error, _} = err -> err
          end
      end
    end
  end

  @doc """
  Starts native time tracking on an issue or PR. An already-active stopwatch succeeds.
  """
  @spec start_stopwatch(String.t(), integer(), Keyword.t()) :: :ok | {:error, term()}
  def start_stopwatch(repo, number, opts \\ []) do
    with {:ok, config} <- resolve_config(opts) do
      case http_post(config, "/repos/#{encode_repo(repo)}/issues/#{number}/stopwatch/start", nil) do
        {:ok, _} -> :ok
        {:error, {:http, 409, _}} -> :ok
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Stops native time tracking. An already-stopped stopwatch succeeds.
  """
  @spec stop_stopwatch(String.t(), integer(), Keyword.t()) :: :ok | {:error, term()}
  def stop_stopwatch(repo, number, opts \\ []) do
    with {:ok, config} <- resolve_config(opts) do
      case http_post(config, "/repos/#{encode_repo(repo)}/issues/#{number}/stopwatch/stop", nil) do
        {:ok, _} -> :ok
        {:error, {:http, 409, _}} -> :ok
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Closes the issue, and SAYS WHICH KIND OF CLOSURE IT IS. PATCH `state: closed`, idempotent on the
  Gitea side.

  `:closure` is MANDATORY — an unnamed closure is refused, loudly, rather than defaulted:

    * `:delivered` — the work landed (seal after merge, terminal step). Stamps `stage/merged`.
    * `:retired` — the ticket dies WITHOUT delivering: its work moved (supersede) or was dropped.
      Stamps `stage/retired`.
    * `:marker` — not a ticket at all (parking markers of `ProjectOnboard`). Stamps nothing.

  WHY THE ARGUMENT IS REQUIRED, AND NOT DERIVED. Left unstated, "a closed ticket is a delivered
  ticket" is EMERGENT: it holds only because no actor owns a close gesture — the human's team is
  `read`, the architect has no close tool, and every closing path is runtime. An invariant resting
  on the absence of a tool is one new caller away from lying, and everything downstream reads the
  CLOSURE, never the intent: a dependency releases on a closed blocker whatever killed it.

  Deriving the kind from "does it carry `stage/merged`?" would rebuild the same weakness one level
  up — an ABSENCE is not a fact, and the reader would have to guess what silence means. Here the
  caller states it at the only moment where it is known for certain.

  The stamp is best-effort and the close is not rolled back for it: the closure is authoritative,
  the label is its trace. A failed stamp is logged, never swallowed.
  """
  @spec close_issue(String.t(), integer(), Keyword.t()) :: {:ok, :closed} | {:error, term()}
  def close_issue(repo, issue_number, opts \\ []) do
    with {:ok, kind} <- fetch_closure_kind(opts),
         {:ok, config} <- resolve_config(opts),
         {:ok, _} <-
           http_patch(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}", %{
             state: "closed"
           }) do
      stamp_closure(repo, issue_number, kind, opts)
      lift_in_flight_on_retire(repo, issue_number, kind, opts)
      {:ok, :closed}
    end
  end

  defp fetch_closure_kind(opts) do
    case Keyword.get(opts, :closure) do
      kind when kind in [:delivered, :retired, :marker] ->
        {:ok, kind}

      other ->
        {:error,
         {:closure_kind_required,
          "close_issue: `closure:` manquant ou invalide (#{inspect(other)}) — une fermeture qui " <>
            "ne dit pas si elle LIVRE ou si elle RETIRE laisse tout l'aval deviner"}}
    end
  end

  # A `:retired` closure LIFTS the flat `lcars-in-flight` lock. It CANNOT ride on the stamp: the stamp
  # is a SCOPED label (`stage/retired`) and the lock is FLAT — disjoint families, so Gitea's per-scope
  # mutex evicts nothing. Every lifecycle path reaches `close_issue` with the lock already lifted
  # (`StepRunCompleter.unlock/6` removes it before a `:delivered` seal), so this is scoped to the ONE
  # closure with no other place to lift it: the supersede/retire gesture (`Delegation.do_retire*`)
  # closes a ticket that may still be IN FLIGHT — a live pod is reaped in the same act — and would
  # leave the lock behind on the now-closed ticket. Best-effort like the stamp: the close is
  # authoritative, and a stale lock on a CLOSED ticket is a warning, never a rollback. Idempotent
  # (`remove_label` no-ops when the label is absent), so it is safe on a retire target that never
  # carried it.
  defp lift_in_flight_on_retire(repo, n, :retired, opts) do
    case remove_label(repo, n, Fleet.Labels.in_flight(), opts) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "ForgeClient: #{repo}##{n} retired but `#{Fleet.Labels.in_flight()}` NOT lifted " <>
            "(#{inspect(reason)}) — stale lock left on a closed ticket"
        )

        :ok
    end
  end

  defp lift_in_flight_on_retire(_repo, _n, _kind, _opts), do: :ok

  defp stamp_closure(_repo, _n, :marker, _opts), do: :ok

  defp stamp_closure(repo, n, kind, opts) do
    stage =
      case kind do
        :delivered -> Fleet.Labels.stage_merged()
        :retired -> Fleet.Labels.stage_retired()
      end

    label = Fleet.Labels.stage_prefix() <> stage

    case add_label(repo, n, label, opts) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "ForgeClient: #{repo}##{n} closed (#{kind}) but the `#{label}` stamp FAILED " <>
            "(#{inspect(reason)}) — the closure stands, its nature is not readable on the ticket"
        )

        :ok
    end
  end

  @doc """
  The issues BLOCKING `number` (what it waits on), as returned by the forge.

  Gitea carries issue dependencies natively and enforces them where it matters: it refuses to CLOSE
  an issue while a blocker is still open. So this is a read, never a rule we re-implement — same
  stance as branch-protection.

  ⚠ A CLOSED blocker counts as satisfied. That is what makes the supersede path load-bearing: a
  retired ticket keeps the edges pointing at it, and closing it RELEASES everything it blocked —
  while the work moved to its replacement and is not delivered (measured 2026-08-04 on the bench).
  """
  @spec issue_dependencies(String.t(), integer(), Keyword.t()) ::
          {:ok, [map()]} | {:error, term()}
  def issue_dependencies(repo, number, opts \\ []) when is_binary(repo) and is_integer(number) do
    with {:ok, config} <- resolve_config(opts) do
      paginate(config, "/repos/#{encode_repo(repo)}/issues/#{number}/dependencies", "")
    end
  end

  @doc "The issues `number` BLOCKS (the inverse edge of `issue_dependencies/3`)."
  @spec issue_blocks(String.t(), integer(), Keyword.t()) :: {:ok, [map()]} | {:error, term()}
  def issue_blocks(repo, number, opts \\ []) when is_binary(repo) and is_integer(number) do
    with {:ok, config} <- resolve_config(opts) do
      paginate(config, "/repos/#{encode_repo(repo)}/issues/#{number}/blocks", "")
    end
  end

  @doc """
  Adds "`number` depends on `blocker`" (same repo).

  THE BODY FIELD IS `repo`, NOT `name`. The swagger's `IssueMeta` says `name`; sending it yields
  `404 IsErrRepoNotExist [id: 0, uid: 0]` — an error that accuses the repository while the body is
  what is wrong. Measured against a live Gitea 1.26.1 on 2026-08-04; both spellings were tried.
  """
  @spec add_issue_dependency(String.t(), integer(), integer(), Keyword.t()) ::
          {:ok, map()} | {:error, term()}
  def add_issue_dependency(repo, number, blocker, opts \\ [])
      when is_binary(repo) and is_integer(number) and is_integer(blocker) do
    [owner, name] = String.split(repo, "/", parts: 2)

    with {:ok, config} <- resolve_config(opts) do
      http_post(
        config,
        "/repos/#{encode_repo(repo)}/issues/#{number}/dependencies",
        %{index: blocker, owner: owner, repo: name}
      )
    end
  end

  @doc """
  Removes "`number` depends on `blocker`" (same repo). Inverse of `add_issue_dependency/4`.

  Same body shape and the same `repo`-not-`name` trap: the edge is identified by the OBJECT, so the
  DELETE carries a body (see `Transport.http_delete_body/3`).

  Needed because a retirement must not leave its edges behind. Closing a blocker RELEASES what it
  blocked, so a dependent whose blocker is retired would silently become closable as if the work had
  landed — the retired ticket delivered nothing. Lifting the edge and NAMING the retirement on the
  dependent is what keeps "unblocked" from meaning "done".
  """
  @spec remove_issue_dependency(String.t(), integer(), integer(), Keyword.t()) ::
          {:ok, map()} | {:error, term()}
  def remove_issue_dependency(repo, number, blocker, opts \\ [])
      when is_binary(repo) and is_integer(number) and is_integer(blocker) do
    [owner, name] = String.split(repo, "/", parts: 2)

    with {:ok, config} <- resolve_config(opts) do
      http_delete_body(
        config,
        "/repos/#{encode_repo(repo)}/issues/#{number}/dependencies",
        %{index: blocker, owner: owner, repo: name}
      )
    end
  end

  @doc "Org repos (WS3 discovery, org-membership = admission). See `ForgeClient.Repo.list_org_repos/2`."
  @spec list_org_repos(String.t(), Keyword.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_org_repos(org, opts \\ []), do: Repo.list_org_repos(org, opts)

  @doc "Repos in a human's personal space — the deposit candidates (cf. `Repo.list_user_repos/2`)."
  @spec list_user_repos(String.t(), Keyword.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_user_repos(login, opts \\ []), do: Repo.list_user_repos(login, opts)

  @doc "Whether a repo is PRIVATE on the forge (cf. `Repo.private?/2`)."
  @spec private?(String.t(), Keyword.t()) :: {:ok, boolean()} | {:error, term()}
  def private?(repo, opts \\ []), do: Repo.private?(repo, opts)

  @doc "Transfere un depot vers une autre org. Cf. `Fleet.Forge.Client.Repo.transfer_repo/3`."
  @spec transfer_repo(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def transfer_repo(repo, new_owner, opts \\ []), do: Repo.transfer_repo(repo, new_owner, opts)

  @doc "Numeric forge id of the repo. See `Fleet.Forge.Client.Repo.repo_id/2`."
  @spec repo_id(String.t(), Keyword.t()) :: {:ok, integer()} | {:error, term()}
  def repo_id(repo, opts \\ []), do: Repo.repo_id(repo, opts)

  @doc """
  Creates an issue and returns its number. `:assignees` are logins; `:labels` are numeric ids.
  """
  @spec create_issue(String.t(), String.t(), String.t(), Keyword.t()) ::
          {:ok, integer()} | {:error, term()}
  def create_issue(repo, title, body, opts \\ [])
      when is_binary(repo) and is_binary(title) and is_binary(body) do
    with {:ok, config} <- resolve_config(opts) do
      attrs = %{
        title: title,
        body: body,
        assignees: Keyword.get(opts, :assignees, []),
        labels: Keyword.get(opts, :labels, [])
      }

      case http_post(config, "/repos/#{encode_repo(repo)}/issues", attrs) do
        {:ok, %{"number" => number}} -> {:ok, number}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Resolves a repository label name to its numeric id across all pages.

  Returns `{:error, {:label_unknown, name}}` when absent; callers can require labels that must be
  present atomically at issue creation.
  """
  @spec repo_label_id(String.t(), String.t(), Keyword.t()) ::
          {:ok, integer()} | {:error, term()}
  def repo_label_id(repo, name, opts \\ []) when is_binary(repo) and is_binary(name) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, labels} <- paginate(config, "/repos/#{encode_repo(repo)}/labels", "") do
      case Enum.find(labels, &(&1["name"] == name)) do
        %{"id" => id} -> {:ok, id}
        _ -> {:error, {:label_unknown, name}}
      end
    end
  end

  @doc """
  Opens a pull request and returns its number. On conflict, resolves the existing open PR for the
  same head and base. Issue closure remains an explicit post-seal operation.
  """
  @spec open_pr(String.t(), String.t(), String.t(), String.t(), Keyword.t()) ::
          {:ok, integer()} | {:error, term()}
  def open_pr(repo, head, base, title, opts \\ [])
      when is_binary(repo) and is_binary(head) and is_binary(base) and is_binary(title) do
    with {:ok, config} <- resolve_config(opts) do
      attrs = %{head: head, base: base, title: title, body: Keyword.get(opts, :body, "")}

      case http_post(config, "/repos/#{encode_repo(repo)}/pulls", attrs) do
        {:ok, %{"number" => number}} -> {:ok, number}
        {:error, {:http, 409, _}} -> get_pr_for_branch(repo, head, base, opts)
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Creates a branch from a server-known ref, separately from the later content push so their feed
  events can be spaced. Returns `{:error, :branch_exists}` on conflict.
  """
  @spec create_branch(String.t(), String.t(), String.t(), Keyword.t()) :: :ok | {:error, term()}
  def create_branch(repo, branch, old_ref, opts \\ [])
      when is_binary(repo) and is_binary(branch) and is_binary(old_ref) do
    with {:ok, config} <- resolve_config(opts) do
      case http_post(config, "/repos/#{encode_repo(repo)}/branches", %{
             "new_branch_name" => branch,
             "old_ref_name" => old_ref
           }) do
        {:ok, _} -> :ok
        {:error, {:http, 409, _}} -> {:error, :branch_exists}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Finds an open PR by exact head and base across every page, or returns `:pr_not_found`.
  """
  @spec get_pr_for_branch(String.t(), String.t(), String.t(), Keyword.t()) ::
          {:ok, integer()} | {:error, term()}
  def get_pr_for_branch(repo, head, base, opts \\ [])
      when is_binary(repo) and is_binary(head) and is_binary(base) do
    with {:ok, config} <- resolve_config(opts) do
      case paginate(config, "/repos/#{encode_repo(repo)}/pulls", "state=open") do
        {:ok, pulls} ->
          case Enum.find(pulls, &pr_matches_head?(&1, head, base)) do
            %{"number" => number} -> {:ok, number}
            _ -> {:error, :pr_not_found}
          end

        {:error, _} = err ->
          err
      end
    end
  end

  defp pr_matches_head?(pr, head, base) do
    get_in(pr, ["head", "ref"]) == head and get_in(pr, ["base", "ref"]) == base
  end

  @doc """
  Le `owner/name` d'un dépôt, depuis son ID numérique de forge.

  Existe parce que l'identité de canal d'un pod DISPATCHÉ ne porte pas la chaîne `owner/name` : le
  dispatch file `:repo_id` et jamais `:repo`, et ce n'est pas un oubli — le `slot_key` du spawner
  se clef dessus, donc un `nil` y mettrait tous les producteurs et tous les juges de tous les
  projets dans un même seau. L'ID, lui, est toujours là. C'est la traduction qui manquait.

  `{:error, :repo_not_found}` sur 404 — un id inconnu est un fait.
  """
  @spec repo_full_name(integer(), Keyword.t()) :: {:ok, String.t()} | {:error, term()}
  def repo_full_name(repo_id, opts \\ []) when is_integer(repo_id) do
    with {:ok, config} <- resolve_config(opts) do
      case http_get(config, "/repositories/#{repo_id}") do
        {:ok, %{"full_name" => full}} when is_binary(full) and full != "" -> {:ok, full}
        {:ok, _} -> {:error, {:unexpected_repo_shape, repo_id}}
        {:error, {:http, 404, _}} -> {:error, :repo_not_found}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Les deux extrémités d'une PR : `%{head_sha, base_sha, head_ref, base_ref}`.

  Existe pour la SONDE de pertinence, qui a besoin des deux SHAs et pas des deux refs : une branche
  bouge, un SHA non. Mesurer « la suite de cette tête contre le code de cette base » sur des REFS
  reviendrait à mesurer un état qui a pu changer entre la lecture et le run — et le fait porterait
  un nom d'état au lieu d'un état.

  `{:error, :pr_not_found}` sur 404, comme son voisin `get_pr_for_branch/4` : un numéro de PR
  inconnu est un fait, pas une panne de transport.
  """
  @spec pr_refs(String.t(), integer(), Keyword.t()) :: {:ok, map()} | {:error, term()}
  def pr_refs(repo, index, opts \\ []) when is_binary(repo) and is_integer(index) do
    with {:ok, config} <- resolve_config(opts) do
      case http_get(config, "/repos/#{encode_repo(repo)}/pulls/#{index}") do
        {:ok, %{"head" => %{"sha" => hs, "ref" => hr}, "base" => %{"sha" => bs, "ref" => br}}} ->
          {:ok, %{head_sha: hs, head_ref: hr, base_sha: bs, base_ref: br}}

        # Une PR sans ces champs n'est pas une PR qu'on peut sonder : on refuse en le NOMMANT
        # plutôt que de rendre des `nil` qui iraient s'écrire dans les entrées d'un workflow.
        {:ok, other} when is_map(other) ->
          {:error, {:unexpected_pr_shape, Map.keys(other)}}

        {:error, {:http, 404, _}} ->
          {:error, :pr_not_found}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  Requests native PR reviews from the supplied ROLES.

  ROLES, not logins, and the distinction is the whole point. The fleet reasons in roles everywhere;
  the account a role writes under is `<tier>_<role>` and only the forge side needs to know it.
  Forwarding what it is handed straight into the Gitea payload sends a jury of
  `["qualifier", "reviewer"]` to a forge whose accounts are `fleet_qualifier` / `fleet_reviewer`,
  which answers `404 User 'qualifier' not exist` — and the deliverable PR then sits open with no
  judge, forever, since a merge waits on approvals that nobody was ever asked for.

  Same shape as `as_role/2`: the caller names a ROLE, the client resolves what the forge needs.

  An unprojectable role FAILS the whole call rather than being dropped: a jury is a quorum, and
  silently requesting two judges out of three turns a merge gate into a deadlock that looks like
  patience.
  """
  @spec request_review(String.t(), integer(), [String.t()], Keyword.t()) ::
          :ok | {:error, term()}
  def request_review(repo, index, roles, opts \\ [])
      when is_binary(repo) and is_integer(index) and is_list(roles) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, logins} <- forge_logins(roles) do
      case http_post(config, "/repos/#{encode_repo(repo)}/pulls/#{index}/requested_reviewers", %{
             reviewers: logins
           }) do
        {:ok, _} -> :ok
        {:error, _} = err -> err
      end
    end
  end

  defp forge_logins(roles) do
    Enum.reduce_while(roles, {:ok, []}, fn role, {:ok, acc} ->
      case Fleet.Credentials.RoleIdentity.login(role) do
        {:ok, login} -> {:cont, {:ok, [login | acc]}}
        {:error, reason} -> {:halt, {:error, {:role_login_unresolved, role, reason}}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  @doc """
  Posts an approval, change request, or comment as a native durable PR review.
  """
  @spec post_review(
          String.t(),
          integer(),
          :approve | :request_changes | :comment,
          String.t(),
          Keyword.t()
        ) :: :ok | {:error, term()}
  def post_review(repo, index, event, body, opts \\ [])
      when is_binary(repo) and is_integer(index) and is_binary(body) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, gitea_event} <- review_event(event) do
      case http_post(config, "/repos/#{encode_repo(repo)}/pulls/#{index}/reviews", %{
             event: gitea_event,
             body: body
           }) do
        {:ok, _} -> :ok
        {:error, _} = err -> err
      end
    end
  end

  defp review_event(:approve), do: {:ok, "APPROVED"}
  defp review_event(:request_changes), do: {:ok, "REQUEST_CHANGES"}
  defp review_event(:comment), do: {:ok, "COMMENT"}
  defp review_event(other), do: {:error, {:invalid_review_event, other}}

  @doc """
  Closes a pull request WITHOUT merging it — PATCH `state: closed`.

  It exists because retiring a ticket does not, on its own, retire its work. The two rails are
  independent by design: `dispatch_review` polls PULLS, not issues, and it is not lease-guarded. So
  a supersede that closes the ticket while its PR stays open leaves that PR being judged, then
  merged, into a retired ticket.

  A retirement that cannot retire the work is not a retirement, and the operator's intent — stop the
  machine, bound the cost — does not care whether a PR exists.

  Idempotent on the Gitea side, like every close.
  """
  @spec close_pr(String.t(), integer(), Keyword.t()) :: {:ok, :closed} | {:error, term()}
  def close_pr(repo, index, opts \\ []) when is_binary(repo) and is_integer(index) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, _} <-
           http_patch(config, "/repos/#{encode_repo(repo)}/pulls/#{index}", %{state: "closed"}) do
      {:ok, :closed}
    end
  end

  @doc """
  Arme l'AUTO-MERGE d'une PR (`merge_when_checks_succeed`) — le clic unique du rail toolchain.

  Fonction DISTINCTE de `merge_pr/3`, et les deux différences sont le sujet :
    * `merge_pr` supprime la head sur succès (`delete_head_branch_spaced`) — sur un merge
      PROGRAMMÉ, ça détruirait la branche AVANT que le merge ait lieu ;
    * `merge_pr` traite « no approvals » en fail-loud — ici c'est l'ÉTAT NOMINAL : la PR attend
      sa signature, l'armement dit « merge tout seul QUAND elle arrive ».

  ⚠ N'ARME JAMAIS une branche sans protection : sans `required_approvals`, « quand les conditions
  sont remplies » = TOUT DE SUITE — la PR se merge sans signature et le convergeur applique. La
  garde vit chez l'appelant (`request_toolchain`, config `:toolchain_auto_merge`, défaut OFF —
  posée par le geste d'installation AVEC la protection, jamais l'un sans l'autre).
  """
  @spec schedule_auto_merge(String.t(), integer(), Keyword.t()) :: :ok | {:error, term()}
  def schedule_auto_merge(repo, index, opts \\ []) when is_binary(repo) and is_integer(index) do
    with {:ok, config} <- resolve_config(opts) do
      case http_post(config, "/repos/#{encode_repo(repo)}/pulls/#{index}/merge", %{
             "do" => Keyword.get(opts, :method, "rebase"),
             "merge_when_checks_succeed" => true
           }) do
        {:ok, _} -> :ok
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Merges (PROMOTES) the PR `index` via **`rebase`** by default — the SEAL passes `method: "merge"`
  on a conflict-resolved PR (A0: its resolution IS a merge commit, a rebase drops it) — (Gitea `POST /repos/{repo}/pulls/{index}/merge`,
  `Do: rebase` by default): replays the PR's commits onto the current `main` then fast-forwards →
  stays **LINEAR** (no merge commit, append-only doctrine preserved) AND handles a `main` that has
  advanced under the PR (PARALLEL MULTI-ISSUE: 2 disjoint issues → 2 PRs off the same `main` → the 1st
  merge advances `main`, the 2nd is no longer FF-able but stays mergeable → `rebase` gets it through; `fast-forward-only`
  would wedge it forever).

  **NO FF→rebase cascade**: a 1st attempt that fails throws the PR back into "checking" state
  (Gitea recomputes mergeability ASYNCHRONOUSLY), and the 2nd back-to-back attempt hits that
  window → `405 "Please try again later"` (double-call = double-405; `rebase` alone
  on a stable PR = 200). So A SINGLE call, and the `405 try-again-later` is treated as a
  **TRANSIENT** (bounded retry `@merge_checking_retries` × `merge_retry_delay_ms`, default 800ms — the
  mergeability stabilises in ~1 computation). Any other failure (real conflict, no approvals under
  branch-protection) propagates as-is (fail-loud). `opts[:method]` forces a style (e.g. tests).
  """
  @merge_checking_retries 3
  @spec merge_pr(String.t(), integer(), Keyword.t()) :: :ok | {:error, term()}
  def merge_pr(repo, index, opts \\ []) when is_binary(repo) and is_integer(index) do
    with {:ok, config} <- resolve_config(opts) do
      method = Keyword.get(opts, :method, "rebase")
      delay = Keyword.get(opts, :merge_retry_delay_ms, 800)
      Merge.do_merge(config, repo, index, method, delay, @merge_checking_retries)
    end
  end

  @doc """
  Lists full open PR records under the optional forge-side assignee scope.

  Hybrid (Gitea 1.26.1): `/pulls` has NO `assigned_by` filter; only the issue-shaped list
  `/issues?type=pulls&assigned_by=…` carries it, so each filtered number is expanded with
  `get_pull/3`. Any failed expansion fails the whole read.
  """
  @spec list_open_pulls(String.t(), Keyword.t()) :: {:ok, [map()]} | {:error, term()}
  def list_open_pulls(repo, opts \\ []) when is_binary(repo) do
    with {:ok, pr_issues} <- list_scoped_issues(repo, "pulls", opts) do
      pr_issues |> Enum.map(& &1["number"]) |> fetch_pulls(repo, opts)
    end
  end

  # Fetches the COMPLETE shape of each PR (head/head.sha/requested_reviewers) for the filtered
  # numbers. Fail-fast preserved: an error on a single PR fails the whole set — we never dispatch on
  # a partial view, the same rule as pagination.
  #
  # ⚠ LE N+1 EST STRUCTUREL COTE FORGE : l'endpoint qui porte le scoping rend des objets ISSUE,
  # sans `head.sha` ni reviewers demandes — d'ou une requete par numero, qu'aucun contournement ne
  # retire tant que la forge ne rend pas le champ.
  #
  # Ce qui EST retirable est la SEQUENTIALITE : ces requetes sont independantes et sans effet de
  # bord, et les enchainer ferait payer au tick la SOMME des latences la ou le maximum suffit. La
  # concurrence est BORNEE parce qu'elles partagent le meme pool de connexions — en ouvrir N
  # echangerait de la lenteur contre de la saturation.
  #
  # ⚠ ET LE CACHE SUR `updated_at` EST DELIBEREMENT NON FAIT : la clef d'invalidation serait ce
  # champ, donc une seule mutation qui ne le bouge pas servirait une PR PERIMEE a une decision de
  # MERGE. Le faire demanderait de VERIFIER quelles mutations le bougent, pas de le supposer.
  defp fetch_pulls(numbers, repo, opts) do
    numbers
    |> Task.async_stream(&get_pull(repo, &1, opts),
      max_concurrency: 8,
      ordered: true,
      # A PR's timeout is already bounded by the transport (`receive_timeout`); this one is the net
      # for the case where the Task itself hangs. `:kill_task` rather than a propagated exit: a PR
      # that does not answer becomes an error of THAT PR, not a crash of the poller.
      timeout: 30_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, pr}}, {:ok, acc} -> {:cont, {:ok, [pr | acc]}}
      {:ok, {:error, _} = err}, _acc -> {:halt, err}
      {:exit, reason}, _acc -> {:halt, {:error, {:pull_fetch_crashed, reason}}}
    end)
    |> case do
      {:ok, prs} -> {:ok, Enum.reverse(prs)}
      err -> err
    end
  end

  @doc """
  Lists the PRs of ONE base branch, all states, FULL records — one paginated call, no N+1.

  Le endpoint `/pulls` (pas `/issues?type=pulls`) rend directement les objets complets
  (`head`/`base`/`merged`) ET filtre `base=` cote serveur. Ecrit pour la passe de drain du
  reconciliateur, qui tourne toutes les 60 s : `list_pulls/2` sur le depot ops y paginerait TOUTES
  les PR du conteneur, puis ferait un GET par PR.
  """
  @spec list_pulls_for_base(String.t(), String.t(), Keyword.t()) ::
          {:ok, [map()]} | {:error, term()}
  def list_pulls_for_base(repo, base, opts \\ [])
      when is_binary(repo) and is_binary(base) do
    with {:ok, config} <- resolve_config(opts) do
      paginate(
        config,
        "/repos/#{encode_repo(repo)}/pulls",
        "state=all&base=" <> URI.encode_www_form(base)
      )
    end
  end

  @doc """
  Lists full open and closed PR records. This N+1 status read preserves review history after merge.
  """
  @spec list_pulls(String.t(), Keyword.t()) :: {:ok, [map()]} | {:error, term()}
  def list_pulls(repo, opts \\ []) when is_binary(repo) do
    with {:ok, pr_issues} <- list_scoped_issues(repo, "pulls", Keyword.put(opts, :state, "all")) do
      pr_issues |> Enum.map(& &1["number"]) |> fetch_pulls(repo, opts)
    end
  end

  @doc "GET a single PR → full shape (head/head.sha/requested_reviewers). Building block of list_open_pulls."
  @spec get_pull(String.t(), integer(), Keyword.t()) :: {:ok, map()} | {:error, term()}
  def get_pull(repo, number, opts \\ []) when is_binary(repo) and is_integer(number) do
    with {:ok, config} <- resolve_config(opts),
         do: http_get(config, "/repos/#{encode_repo(repo)}/pulls/#{number}")
  end

  @doc """
  Counts comments containing `prefix` across all pages. Counting is author-agnostic because a forged
  extra marker can only tighten the consuming budget.
  """
  @spec count_comments_marked(String.t(), integer(), String.t(), Keyword.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def count_comments_marked(repo, issue_number, prefix, opts \\ [])
      when is_binary(repo) and is_integer(issue_number) and is_binary(prefix) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, comments} <-
           paginate(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}/comments", "") do
      {:ok, Enum.count(comments, &String.contains?(&1["body"] || "", prefix))}
    end
  end

  @doc """
  Resolves the merged PR from the latest `[merge:pr-N]` issue marker, not from rewritten branch refs.

  NEVER by branch name: a merged PR's `head.ref` no longer resolves once its head branch is gone,
  so a branch scan cannot find a delivered brick's PR. The measurement that establishes it lives
  with the marker it justifies, in `Fleet.Forge.Protocol.merge_marker/1`.

  Returns `:none` only after a successful complete comment read. The marker is author-agnostic
  because it is observability-only and the gatekeeper role, not necessarily the system bot, writes
  it.
  """
  @spec merged_pr_of_issue(String.t(), integer(), Keyword.t()) ::
          {:ok, map()} | :none | {:error, term()}
  def merged_pr_of_issue(repo, issue_number, opts \\ [])
      when is_binary(repo) and is_integer(issue_number) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, comments} <-
           paginate(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}/comments", "") do
      comments
      |> Enum.reverse()
      |> Enum.find_value(fn c ->
        case ForgeProtocol.parse_merge_marker(c["body"] || "") do
          {:ok, n} -> n
          :error -> nil
        end
      end)
      |> case do
        nil -> :none
        pr_number -> get_pull(repo, pr_number, opts)
      end
    end
  end

  @doc "Jury state (verdicts + jury SET + outcome) of a PR. See `Fleet.Forge.Client.Jury.pr_review_state/3`."
  @spec pr_review_state(String.t(), integer(), Keyword.t()) :: {:ok, term()} | {:error, term()}
  def pr_review_state(repo, index, opts \\ []), do: Jury.pr_review_state(repo, index, opts)

  @doc "Feedback of the REQUEST_CHANGES in force. See `Fleet.Forge.Client.Jury.change_request_feedback/3`."
  @spec change_request_feedback(String.t(), integer(), Keyword.t()) ::
          {:ok, term()} | {:error, term()}
  def change_request_feedback(repo, index, opts \\ []),
    do: Jury.change_request_feedback(repo, index, opts)

  @doc """
  Counts the largest same-base group of durable publish-failure markers for issue `n`.

  A successful push advances the base, so each group is one consecutive failure streak.
  """
  @spec count_publish_failures(String.t(), integer(), Keyword.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def count_publish_failures(repo, n, opts \\ []) when is_binary(repo) and is_integer(n) do
    with {:ok, comments} <- list_comments(repo, n, opts) do
      streak =
        comments
        |> Enum.map(&ForgeProtocol.parse_publish_fail_marker(Map.get(&1, "body", "")))
        |> Enum.filter(&match?({:ok, {^n, _}}, &1))
        |> Enum.frequencies()
        |> Map.values()
        |> Enum.max(fn -> 0 end)

      {:ok, streak}
    end
  end

  @doc "Counts the rework rounds. See `Fleet.Forge.Client.Jury.count_change_request_rounds/3`."
  @spec count_change_request_rounds(String.t(), integer(), Keyword.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def count_change_request_rounds(repo, index, opts \\ []),
    do: Jury.count_change_request_rounds(repo, index, opts)

  @doc """
  Worst CI state on `sha` — `:success | :pending | :failure | :none` (Gitea
  `GET /repos/{repo}/commits/{sha}/statuses`).

  WHY A WORST-OF AND NOT THE RAW LIST. A commit carries ONE context per workflow-job-trigger pair,
  so a Gitea Actions run posts BOTH `CI / ci (push)` and `CI / ci (pull_request)` on the same sha
  (measured 2026-08-03). The caller's question is never "which contexts exist" but "may this merge
  proceed", and a single failure answers it — reducing here keeps that judgement in one place
  instead of leaving each caller to re-derive it, differently.

  `:none` (no status at all) is DISTINCT from `:success` on purpose: a repo with no CI and a repo
  whose CI passed are not the same fact, and collapsing them would let "the rail never ran" wear
  the face of "the rail is green". The caller decides what an absent rail means for it.

  Per context, the CURRENT status wins — an older green must never outvote the current red. The rank
  is read from the DATA (`id`), never from the order of the response: measured on Gitea 1.26.1, the
  default order is OLDEST-first and only `sort=leastindex` returns newest-first, its name saying the
  opposite of what it does. An order is not a contract you can verify locally.
  """
  @spec commit_ci_state(String.t(), String.t(), Keyword.t()) ::
          {:ok, :success | :pending | :failure | :none} | {:error, term()}
  def commit_ci_state(repo, sha, opts \\ []) when is_binary(repo) and is_binary(sha) do
    with {:ok, {state, _contexts}} <- commit_ci_report(repo, sha, opts), do: {:ok, state}
  end

  @doc """
  The same verdict, plus the CONTEXTS that produced it (sorted, deduplicated).

  The worst-of alone answers the merge question, and it is the WHOLE answer only for a caller that
  decides. A caller that must TELL A HUMAN (or a judge)
  what the machine did needs to say WHICH rail ran, because `:success` is silent about that and a
  green from a placeholder rail is indistinguishable from a green from a real harness (6-140).

  Additive on purpose: `commit_ci_state/3` keeps its contract and every seam that implements it
  keeps working. A caller pays for the contexts only where it renders them.
  """
  @spec commit_ci_report(String.t(), String.t(), Keyword.t()) ::
          {:ok, {:success | :pending | :failure | :none, [String.t()]}} | {:error, term()}
  def commit_ci_report(repo, sha, opts \\ []) when is_binary(repo) and is_binary(sha) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, statuses} <-
           paginate(config, "/repos/#{encode_repo(repo)}/commits/#{encode_seg(sha)}/statuses", "") do
      contexts =
        statuses
        |> Enum.map(& &1["context"])
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()
        |> Enum.sort()

      {:ok, {statuses |> CI.current_per_context() |> CI.worst_ci_state(), contexts}}
    end
  end

  @doc """
  Les contextes ACTUELLEMENT rouges sur `sha` — `context`, `description`, `target_url`.

  Un pod est forge-blind : il n'ouvre aucune page. La cause d'un rework CI doit donc voyager DANS
  le brief, et une cause tient au NOM du contexte en échec — jamais à la liste complète, qui
  accuserait les verts.

  ⚠ ORDRE INDÉTERMINABLE = PAS D'ACCUSATION, et c'est l'inverse de `commit_ci_state/3`. Quand les
  ids d'un contexte ne s'ordonnent pas, `current_per_context/1` garde tout le groupe pour que la
  porte de merge y lise le PIRE. Ici la lecture sert à désigner un coupable : un contexte dont on
  ne sait pas si le rouge est le dernier mot est écarté, et la section dégrade vers son texte
  générique, qui ne nomme personne.
  """
  @spec commit_ci_failures(String.t(), String.t(), Keyword.t()) ::
          {:ok,
           [%{context: String.t(), description: String.t() | nil, target_url: String.t() | nil}]}
          | {:error, term()}
  def commit_ci_failures(repo, sha, opts \\ []) when is_binary(repo) and is_binary(sha) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, statuses} <-
           paginate(config, "/repos/#{encode_repo(repo)}/commits/#{encode_seg(sha)}/statuses", "") do
      {:ok, CI.red_contexts(statuses)}
    end
  end

  @doc "Judges re-requested after judgment (timeline). See `Fleet.Forge.Client.Jury.pr_rerequested_reviewers/3`."
  @spec pr_rerequested_reviewers(String.t(), integer(), Keyword.t()) ::
          {:ok, [String.t()]} | {:error, term()}
  def pr_rerequested_reviewers(repo, index, opts \\ []),
    do: Jury.pr_rerequested_reviewers(repo, index, opts)

  @stage_prefix Fleet.Labels.stage_prefix()
  @wfmap_prefix Fleet.Labels.wfmap_prefix()

  @doc """
  Sets an issue's fixed `wfmap/<pipeline>` and exclusive current `stage/<step>` labels.
  """
  @spec post_route(String.t(), integer(), String.t(), String.t(), Keyword.t()) ::
          {:ok, :posted | :already} | {:error, term()}
  def post_route(repo, issue_number, pipeline, step, opts \\ [])
      when is_binary(pipeline) and is_binary(step) do
    with {:ok, _} <- add_label(repo, issue_number, wfmap_label(pipeline), opts) do
      set_stage(repo, issue_number, step, opts)
    end
  end

  @doc """
  Sets only the exclusive current stage, retaining the issue's workflow-map label.
  """
  @spec set_stage(String.t(), integer(), String.t(), Keyword.t()) ::
          {:ok, :posted | :already} | {:error, term()}
  def set_stage(repo, issue_number, stage, opts \\ []) when is_binary(stage) do
    case add_label(repo, issue_number, stage_label(stage), opts) do
      {:ok, :added} -> {:ok, :posted}
      {:ok, :already_present} -> {:ok, :already}
      {:error, _} = err -> err
    end
  end

  @doc """
  Reads `{workflow_map, stage}` from scoped labels. A missing half returns `:none`; no default map is
  invented.
  """
  @spec get_route(String.t(), integer(), Keyword.t()) ::
          {:ok, {String.t(), String.t()}} | :none | {:error, term()}
  def get_route(repo, issue_number, opts \\ []) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, labels} <- Labels.get_issue_labels(config, repo, issue_number) do
      route_from_labels(labels)
    end
  end

  @doc """
  La route DERIVEE de labels deja en main — pure, zero I/O (BL-6-40 Phase 2).

  `get_route/3` fait un `GET /issues/{n}/labels` par issue et par tick. Or l'appelant chaud
  (`Poller.Lease.classify_issue`) tient DEJA les labels complets : `list_open_issues` les rend avec
  l'issue. Une requete par issue, par repo, par tick, pour une donnee qui est en RAM.

  Deux formes acceptees parce que les deux existent chez les appelants : la forme FIL (maps Gitea
  `%{"name" => …}`, ce que rend `get_issue_labels`) et la liste de NOMS (ce que `classify_issue`
  a deja projete). Accepter les deux evite d'imposer une re-projection a un appelant qui a
  justement fait l'economie.

  `get_route/3` reste, et n'est pas un doublon : un appelant qui n'a pas l'objet issue — une sonde,
  un outil, un chemin qui part d'un numero — ne peut pas deriver ce qu'il n'a pas lu. Il delegue
  ici apres avoir lu, donc la REGLE de derivation n'existe qu'une fois.
  """
  @spec route_from_labels([map() | String.t()]) :: {:ok, {String.t(), String.t()}} | :none
  def route_from_labels(labels) when is_list(labels) do
    normalized =
      Enum.map(labels, fn
        %{"name" => n} -> %{"name" => n}
        n when is_binary(n) -> %{"name" => n}
        _ -> %{"name" => nil}
      end)

    case {current_wfmap(normalized), current_stage(normalized)} do
      {map, step} when is_binary(map) and is_binary(step) -> {:ok, {map, step}}
      _ -> :none
    end
  end

  defp stage_label(step) when is_binary(step), do: @stage_prefix <> step
  defp wfmap_label(map) when is_binary(map), do: @wfmap_prefix <> map

  defp current_stage(labels), do: label_value(labels, @stage_prefix)
  defp current_wfmap(labels), do: label_value(labels, @wfmap_prefix)

  defp label_value(labels, prefix) when is_list(labels) do
    Enum.find_value(labels, fn label ->
      name = label["name"]

      if is_binary(name) and String.starts_with?(name, prefix),
        do: String.replace_prefix(name, prefix, "")
    end)
  end

  @doc """
  Le login de forge sous lequel `role` ecrit, ou `{:error, _}`.

  RIEN D'AUTRE NE DIT SOUS QUEL COMPTE UN ROLE ECRIT. `as_role/2` echange un JETON (`RoleIdentity`
  porte `{role, token}`) ; le compte qui apparait comme auteur est celui qui detient ce jeton SUR LA
  FORGE. Sans cette traduction, tout ce qui filtre sur le login SYSTEME compte ZERO marqueur — ils
  sont tous poses sous un role, cf. F-E6 qui l'exige — et la dedup ne voit jamais le sien, donc le
  repose a chaque rejeu.

  La resolution est le meme geste que pour le bot — `GET /user` avec CE jeton — et son cache est
  deja keye par empreinte de jeton, donc un role resolu une fois ne coute plus rien.
  """
  @spec role_login(String.t(), Keyword.t()) :: {:ok, String.t()} | {:error, term()}
  def role_login(role, opts \\ []) when is_binary(role) do
    with {:ok, role_opts} <- as_role(opts, role),
         {:ok, config} <- resolve_config(role_opts) do
      login_of(config)
    end
  end

  # UN commentaire signe compte-t-il ? Le marqueur nomme un ROLE ; on ne croit ce role que si
  # l'auteur du commentaire est le compte de ce role, ou le compte systeme.
  defp count_signed(c, {:ok, n}, bot, opts) do
    role = ForgeProtocol.step_run_marker_role(c["body"])
    author = get_in(c, ["user", "login"])

    cond do
      author == bot ->
        {:cont, {:ok, n + 1}}

      true ->
        case role_login(role, opts) do
          {:ok, ^author} ->
            {:cont, {:ok, n + 1}}

          {:ok, _other} ->
            {:cont, {:ok, n}}

          # PAS DE JETON POUR CE ROLE = ce role n'existe pas dans cette fleet, donc le marqueur
          # qui le nomme n'a pas pu etre ecrit par elle. Ne pas le compter n'est pas un
          # sous-compte permissif, c'est refuser un faux — et c'est ce qui empeche un tiers de
          # casser le compteur en postant `[step_run:fake:ccc]` (F059 : le fixture le fait).
          {:error, :role_token_unavailable} ->
            {:cont, {:ok, n}}

          # Tout le reste — reseau, forge muette — est une VRAIE incertitude : on echoue plutot
          # que de rendre un total qui pourrait etre bas.
          {:error, reason} ->
            {:halt, {:error, {:role_login_unresolved, role, reason}}}
        end
    end
  end

  @doc """
  Counts the FLEET's step-run markers across all comment pages for the anti-runaway budget.

  UN MARQUEUR DIT QUI IL PRETEND ETRE, ET ON LE VERIFIE. Il compte si son auteur est le login du
  role QU'IL NOMME (ou le bot, pour les marqueurs que le systeme pose lui-meme, cf. `pr-open-fail`).
  Filtrer sur `auteur == login systeme` compterait ZERO : F-E6 exige que ce commentaire soit signe
  par le ROLE qui finit, jamais par le systeme.

  La frontiere de F059 tient, et c'est tout l'enjeu : un `[step_run:fake:ccc]` pose par un tiers ne
  compte pas, puisque son auteur n'est pas le compte du role `fake` — et un compte de role n'est
  detenu que par le daemon, dans `/opt/lcars/var/tokens`.

  Un role dont le login est irresolvable est une ERREUR, jamais un sous-compte permissif.
  """
  @spec count_signed_step_runs(String.t(), integer(), Keyword.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def count_signed_step_runs(repo, issue_number, opts \\ []) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, bot} <- forge_bot_login(config, opts),
         {:ok, comments} when is_list(comments) <-
           paginate(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}/comments", "") do
      comments
      |> Enum.filter(&(ForgeProtocol.step_run_marker_role(&1["body"]) != nil))
      |> Enum.reduce_while({:ok, 0}, &count_signed(&1, &2, bot, opts))
    end
  end

  @doc """
  The last comment carrying an ESCALATION marker, or `nil` — the arch's inbox reads its arbitration
  question through this.

  It exists as a seam function rather than a filter on the MCP side because the marker FORMAT is
  this domain's (`ForgeProtocol` builds it at both writing sites), and the boundary refuses
  `Fleet.MCP -> Fleet.Pilot`. The inbox asks the forge client; the client knows the protocol —
  exactly the shape `get_predecessor_result/3` already has.

  `nil` is a RESULT, not a failure: the recurrence brake (`IncidentConsumer.default_brake/3`) poses
  `lcars-awaits-arch` with NO comment at all, so there is no verdict to hand back. Saying so beats
  handing over the thread's last comment, which would give the arch its own previous answer as the
  question to arbitrate.
  """
  @spec escalation_verdict(String.t(), integer(), Keyword.t()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def escalation_verdict(repo, issue_number, opts \\ []) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, comments} when is_list(comments) <-
           paginate(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}/comments", "") do
      body =
        comments
        |> Enum.reverse()
        |> Enum.find_value(fn c ->
          b = is_map(c) and c["body"]
          if is_binary(b) and ForgeProtocol.escalation_marker?(b), do: b
        end)

      {:ok, body}
    end
  end

  @doc """
  Extracts the latest result block from system-authored comments for the next judge's brief.
  """
  @spec get_predecessor_result(String.t(), integer(), Keyword.t()) ::
          {:ok, map()} | :none | {:error, term()}
  def get_predecessor_result(repo, issue_number, opts \\ []) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, bot} <- forge_bot_login(config, opts),
         {:ok, comments} when is_list(comments) <-
           paginate(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}/comments", "") do
      comments
      |> Enum.filter(&ForgeProtocol.system_authored?(&1, bot))
      |> Enum.map(& &1["body"])
      |> Enum.reverse()
      |> Enum.find_value(:none, &ForgeProtocol.parse_result_block/1)
    end
  end

  @doc """
  Ensures static lock, destination, and stage labels exist with their protocol metadata.

  Success is based on complete readback, not create responses. Missing or unreadable labels return
  `:labels_missing` or `:labels_unverifiable`; dynamic workflow-map labels are not seeded.
  """

  # LES CONSTANTES DE PROTOCOLE VIENNENT DE `Fleet.Labels`, ET C'EST SON CONTRAT, PAS UN STYLE.
  # Son `@moduledoc` l'écrit : « Re-declaring one as a local `@attr` or literal = silent drift on a
  # rename. Centralized here, consumed everywhere. » Les épeler en littéral — dans la liste de
  # seeding comme dans les clauses de `label_color/1` / `label_description/1` — laisse ici autant de
  # chaînes orphelines au premier renommage côté Labels, sans un mot. Attributs évalués à la
  # compilation (la forme que le moduledoc prescrit), utilisables en PATTERN.

  @spec ensure_protocol_labels(String.t(), keyword()) :: :ok | {:error, term()}
  def ensure_protocol_labels(repo, opts \\ []) when is_binary(repo) do
    with {:ok, config} <- resolve_config(opts) do
      statics =
        [
          Fleet.Labels.in_flight(),
          Fleet.Labels.awaits_arch(),
          # Genre marker (face-projet): the arch poses it at create_issue, the burn reads
          # it — it must exist on every fleet repo or add_label fails the ticket's genre silently.
          Fleet.Labels.destination_workshop(),
          # `brief-review` and `build` stay LITERAL, and that is not an oversight: they are step
          # names carried by the workflow MAPS (data), not protocol constants — `Fleet.Labels` says
          # so itself ("brief-review/build values come from the MAP"). Seeding them here pre-creates
          # the two canonical steps' labels; a card naming other steps gets them on demand.
          "stage/brief-review",
          "stage/build",
          Fleet.Labels.stage_prefix() <> Fleet.Labels.stage_review(),
          Fleet.Labels.stage_prefix() <> Fleet.Labels.stage_merged(),
          # RETIRED is seeded for the PALETTE, not for routing — `add_issue_label/4` creates a
          # label on demand when the POST does not take. A lazily-created label is born with the
          # default grey and no description, so the ONE stage that says "closed without delivering"
          # would read as noise next to five coloured ones.
          Fleet.Labels.stage_prefix() <> Fleet.Labels.stage_retired()
        ] ++ Fleet.Labels.visual_types()

      Enum.each(statics, &Labels.ensure_repo_label(config, repo, &1))
      Labels.verify_labels_present(config, repo, statics)
    end
  end

  @doc """
  Replaces forge credentials with a role token so the system acts under that role's identity.

  Invalid, missing, unreadable, or empty role credentials return `:role_token_unavailable`; there is
  no fallback to the privileged system token. Pods remain forge-blind.
  """
  @spec as_role(keyword(), String.t() | nil) ::
          {:ok, keyword()} | {:error, :role_token_unavailable}
  def as_role(forge_opts, role) do
    case Fleet.Credentials.RoleIdentity.for_role(role) do
      {:ok, identity} -> {:ok, Keyword.put(forge_opts, :token, identity.token)}
      {:error, _} = err -> err
    end
  end
end
