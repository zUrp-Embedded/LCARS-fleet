defmodule Fleet.Workflow.DeliverableGate do
  @moduledoc """
  Deliverable gate (makes an invalid state unrepresentable at push) — verifies MECHANICALLY, on the
  world side (Elixir), that a pod workspace can be pushed to the forge. Does NOT trust the pod: reads
  its `.git` read-only, reads no assertion from the pod. Each failed check = fail-loud typed
  `{:error, reason}` (the push does NOT happen). Shared by both modes (`payload` / `git_native`) of
  `Fleet.Workflow.Deliverable`.

  The three invariants verified:

  - **base ancestor** `check_base_ancestor/2` — the base SHA (captured off-pod at clone) MUST be an
    ancestor of HEAD: no history rewrite (`git reset --hard base~5` rejected).
  - **identity** `check_identity/3` — every commit in `base..HEAD` has author AND committer ∈ authorized
    identities (`LCARS-<role>`): identity is verified at the world boundary, not trusted from the pod.
  - **secrets** `scan_secrets/2` — no secret in the `base..HEAD` diff (the pod has an OAuth token in env;
    `env > t && git add -A && commit` must be blocked before push).

  The system-chosen target branch and the forge network isolation are outside this module
  (resp. `Fleet.Workflow.Deliverable.publish` and the bwrap containment).

  **Last revised**: 2026-08-02
  """

  @git_timeout_ms 15_000

  # High-signal patterns (low false-positive). The pod's OAuth token is a JWT `eyJ…`.
  @secret_patterns [
    {~r/sk-ant-[A-Za-z0-9_\-]{8,}/, "anthropic_key"},
    {~r/eyJ[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{10,}/, "jwt_token"},
    {~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/, "private_key"},
    {~r/AKIA[0-9A-Z]{16}/, "aws_access_key"},
    {~r/ghp_[A-Za-z0-9]{36}/, "github_pat"}
  ]

  # Files forbidden in a diff (creds/secrets by name). Match on basename.
  @secret_file_re ~r/(^|\/)(\.credentials\.json|\.env(\..+)?|\.netrc|\.tok|id_rsa.*|.*\.pem|.*\.key)$/

  @type reason ::
          {:base_not_ancestor, String.t()}
          | {:bad_identity, [String.t()]}
          | {:missing_coauthor_trailer, String.t(), [String.t()]}
          | {:secret_detected, String.t(), String.t()}
          | {:git_error, term()}
          # Git timeout, distinct from the "not ancestor" diagnostic and from a hard git error.
          | {:git_timeout, term()}

  @doc """
  Composite: all checks over `[base_sha..HEAD]` of `workspace`. `allowed_emails` = the list of
  accepted identity emails (typically `["<role>@lcars.local"]`). `{:ok, :verified}` or the FIRST
  `{:error, reason}`. Order: base → identity → secrets.
  """
  @spec verify(Path.t(), String.t(), [String.t()], String.t() | nil) ::
          {:ok, :verified} | {:error, reason()}
  def verify(workspace, base_sha, allowed_emails, expected_role \\ nil) do
    with :ok <- check_base_ancestor(workspace, base_sha),
         :ok <- check_identity(workspace, base_sha, allowed_emails),
         :ok <- maybe_check_trailer(workspace, base_sha, expected_role),
         :ok <- scan_secrets(workspace, base_sha) do
      {:ok, :verified}
    end
  end

  # Role-trailer facet of identity, opt-in via `expected_role`. nil → skip (system payload
  # mode / back-compat). Set in `git_native` (the pod commits + signs its role).
  defp maybe_check_trailer(_workspace, _base_sha, nil), do: :ok

  defp maybe_check_trailer(workspace, base_sha, role) when is_binary(role),
    do: check_coauthor_trailer(workspace, base_sha, role)

  @doc "`base_sha` must be an ancestor of HEAD (no history rewrite)."
  @spec check_base_ancestor(Path.t(), String.t()) :: :ok | {:error, reason()}
  def check_base_ancestor(workspace, base_sha) do
    # The rc-typed ancestor mechanic is SHARED with the provenance verifier
    # (`Fleet.Workflow.Git.ancestor?/3` — one mechanic, two consumers); only the
    # DIAGNOSTIC shaping is this gate's business.
    case Fleet.Workflow.Git.ancestor?(workspace, base_sha, "HEAD") do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        # DIAGNOSTIC message. `merge-base --is-ancestor` outputs NOTHING on the nominal failure
        # case, and the old message named the BASE but not what HEAD actually was — the faceproof
        # rework loop failed five identical rounds with "<base> ⊄ HEAD" and the one fact that
        # would have discriminated an amend (same parent, new sha) from a reset-to-elsewhere died
        # unlogged each time; the bench was destroyed before anyone could ask the workspace. HEAD
        # and its parent cost one local rev-parse ON THE FAILURE PATH ONLY and turn the next such
        # loop into a one-log diagnosis.
        {:error,
         {:base_not_ancestor,
          "#{String.slice(to_string(base_sha), 0, 12)} ⊄ HEAD=#{head_diag(workspace)}"}}

      {:error, {:git_timeout, _} = e} ->
        {:error, e}

      {:error, {:git_error, _} = e} ->
        {:error, e}

      # Any other unexpected shape: fail-closed as `:git_error` (never a false `base_not_ancestor`).
      {:error, other} ->
        {:error, {:git_error, "merge-base: #{inspect(other)}"}}
    end
  end

  # HEAD and its first parent, short, for the base_not_ancestor diagnostic — failure path only.
  # Best-effort by design: this is a MESSAGE decorator, and a broken rev-parse must not turn a
  # precise `base_not_ancestor` into a vague `git_error` (the check above already ran).
  defp head_diag(workspace) do
    case rev_parse_short(workspace, "HEAD") do
      {:ok, head} ->
        case rev_parse_short(workspace, "HEAD~1") do
          {:ok, parent} -> "#{head} (parent #{parent})"
          _ -> "#{head} (root)"
        end

      _ ->
        "unreadable"
    end
  end

  # Split calls ON PURPOSE: `rev-parse A B` prints the fatal BEFORE the resolved line when B is
  # unresolvable (root HEAD), poisoning the whole output.
  defp rev_parse_short(workspace, ref) do
    case Fleet.Credentials.Shell.git(
           ["rev-parse", "--short=12", ref],
           cd: workspace,
           timeout_ms: 5_000
         ) do
      {:ok, {out, 0}} -> {:ok, String.trim(out)}
      _ -> :error
    end
  end

  @doc """
  Every commit in `base..HEAD` has author email AND committer email ∈ `allowed`.
  Empty range (no commit) → `:ok` (vacuity; the presence of a commit is handled outside the gate, mode-side).
  """
  @spec check_identity(Path.t(), String.t(), [String.t()]) :: :ok | {:error, reason()}
  def check_identity(workspace, base_sha, allowed) do
    case git(workspace, ["log", "#{base_sha}..HEAD", "--format=%ae%n%ce"]) do
      {out, 0} ->
        # A commit with an EMPTY author/committer email must NOT bypass the gate: `String.split(…,
        # trim: true)` would DROP the empty lines → the empty email would NEVER be compared to the allow-list →
        # `Enum.reject([])` = `[]` → `:ok` (bypass). An EMPTY email is an ILLEGAL identity (not
        # `LCARS-<role>`) → it MUST be rejected, not swept away.
        #
        # ANTI-REGRESSION: do NOT force a `%x00` separator that would produce a terminal false positive
        # `[""]` breaking EVERY clean deliverable. The discrimination is SHARP:
        #   - EMPTY range (no commit) → git returns `out == ""` (0 byte) → `:ok` (vacuity);
        #   - 1 commit with empty emails → git returns `"\n\n"` (2 bytes) → we strip the SINGLE TRAILING `\n`
        #     (`replace_suffix`, NOT `trim_trailing` which would ALSO eat the empty-email lines and
        #     re-conflate with the empty range) → `"\n"` → split → `["", ""]` → empty emails detected.
        #   - clean deliverable → non-empty emails → no `""` → :ok.
        case out do
          # Empty range (no new commit) → `:ok` (vacuity; presence of a commit handled mode-side).
          "" ->
            :ok

          _ ->
            emails =
              out
              |> String.replace_suffix("\n", "")
              |> String.split("\n")
              |> Enum.map(&String.trim/1)

            allowed_set = MapSet.new(allowed)

            # An empty email (`""`) is NEVER in the allow-list (`<role>@lcars.local`) → rejected by
            # `Enum.reject` just like a spoofed email. We make it EXPLICIT in the diagnostic
            # (`<empty-email>`) so as not to display an unreadable empty string in the `{:bad_identity}`.
            case Enum.reject(emails, &MapSet.member?(allowed_set, &1)) do
              [] -> :ok
              bad -> {:error, {:bad_identity, bad |> Enum.map(&label_email/1) |> Enum.uniq()}}
            end
        end

      {out, rc} ->
        {:error, classify_git_error(out, rc)}
    end
  end

  # Makes an empty email READABLE in the `{:bad_identity}` diagnostic (otherwise `""` in the list goes
  # unnoticed). The email stays rejected by construction (not in the allow-list); this only changes the display.
  defp label_email(""), do: "<empty-email>"
  defp label_email(e), do: e

  @doc """
  Trailer facet of identity — every commit in `base..HEAD` carries the EXPECTED
  `Co-authored-by: LCARS-<role>` trailer (the machine signature of the role is verified at the
  world boundary, not trusted from the pod; role ↔ step = `expected_role`, set by the
  caller). Empty range → `:ok` (vacuity). A commit without the trailer → fail-loud
  `{:missing_coauthor_trailer, expected_role, [sha…]}` (the push does not happen).

  Wired in `verify/4` via `expected_role` (opt-in). git_native → the pod signs
  its role (brief instructed by `Pilot.BriefBuilder.build_brief`); system payload → `nil` (skip).
  The git author = the human; the role = THIS trailer, verified at the world boundary.
  """
  @spec check_coauthor_trailer(Path.t(), String.t(), String.t()) :: :ok | {:error, reason()}
  def check_coauthor_trailer(workspace, base_sha, expected_role) when is_binary(expected_role) do
    # Codex audit F-03 (2026-07-19): the old check did `String.contains?(body, "Co-authored-by:
    # LCARS-<role>")` over the WHOLE message — a PROSE line quoting the marker (an audit note, a
    # review comment) passed the attestation without a real trailer. We now extract the ACTUAL
    # Git trailers via `--format=%(trailers:key=Co-authored-by,valueonly)` (git parses the last
    # paragraph's trailer block — prose in the body is NOT a trailer) and match the role on the
    # trailer VALUE. Needle = `LCARS-<role>`, derived from the canonical trailer (ForgeIdentity =
    # SINGLE SOURCE), the prefix before the email (lenient on the address).
    needle =
      Fleet.Credentials.ForgeIdentity.coauthor_trailer(expected_role)
      |> String.replace_prefix("Co-authored-by: ", "")
      |> String.split(" <")
      |> hd()

    # `%x00` separates commits, `%x1f` (unit separator) the sha from the extracted trailer values —
    # neither can appear in a git message/trailer.
    case git(workspace, [
           "log",
           "#{base_sha}..HEAD",
           "--format=%H%x1f%(trailers:key=Co-authored-by,valueonly)%x00"
         ]) do
      {out, 0} ->
        missing =
          out
          |> String.split(<<0>>, trim: true)
          |> Enum.flat_map(fn chunk ->
            case String.split(chunk, <<0x1F>>, parts: 2) do
              # `values` = the newline-joined VALUES of the real Co-authored-by trailers (empty if
              # none). A commit is covered iff ONE trailer value starts with `LCARS-<role>`.
              [sha, values] ->
                covered? =
                  values
                  |> String.split("\n", trim: true)
                  |> Enum.any?(&(String.trim_leading(&1) |> String.starts_with?(needle)))

                if covered?, do: [], else: [String.trim(sha)]

              _ ->
                []
            end
          end)

        case missing do
          [] -> :ok
          shas -> {:error, {:missing_coauthor_trailer, expected_role, shas}}
        end

      {out, rc} ->
        {:error, classify_git_error(out, rc)}
    end
  end

  @doc """
  PER-COMMIT scan of `base..HEAD`: secret patterns (tokens/keys) in the ADDED CONTENT + forbidden file
  names. `:ok` if clean, otherwise `{:error, {:secret_detected, kind, hint}}`.

  The scan is PER-COMMIT (`git log -p`/`--name-only`), NOT over the NET diff `base..HEAD`. The net
  diff is blind to a secret INTRODUCED then REMOVED in the chain (`env > t && commit` then `rm t &&
  commit` → NET diff EMPTY), whereas the PUSH transfers the WHOLE chain → the secret would remain in
  the forge history. Scanning each commit (an EXACT mirror of what `check_identity`/
  `check_coauthor_trailer` already do over the chain) closes this evasion: the commit that INTRODUCED the secret carries the offending `+` line.
  """
  @spec scan_secrets(Path.t(), String.t()) :: :ok | {:error, reason()}
  def scan_secrets(workspace, base_sha) do
    with :ok <- scan_secret_filenames(workspace, base_sha) do
      scan_secret_content(workspace, base_sha)
    end
  end

  defp scan_secret_filenames(workspace, base_sha) do
    # `log --name-only` lists the files touched BY EACH commit of the chain (a secret file added then
    # deleted shows up in the add commit), whereas `diff --name-only base..HEAD` would see only the NET
    # (a file deleted at the end of the chain → invisible). `--pretty=format:` removes the commit headers
    # (we want only the file names).
    #
    # `--diff-merges=first-parent`: WITHOUT it, `git log -p` emits NO diff for a MERGE commit → a
    # forbidden file introduced ONLY in the RESOLVED tree of an evil-merge (present in NEITHER parent,
    # base still an ancestor, legitimate author) would pass the scan and be pushed. The option makes it
    # emit, for each merge, the delta vs its FIRST parent (= what the merge introduces into the
    # mainline) → the file of the resolved tree becomes visible again. Does NOT alter the linear scan (each
    # non-merge commit keeps its per-commit diff).
    case git(workspace, [
           "log",
           "-p",
           "--name-only",
           "--diff-merges=first-parent",
           "--pretty=format:",
           "#{base_sha}..HEAD"
         ]) do
      {out, 0} ->
        files = String.split(out, "\n", trim: true)

        case Enum.find(files, &Regex.match?(@secret_file_re, &1)) do
          nil -> :ok
          f -> {:error, {:secret_detected, "blacklisted_file", f}}
        end

      {out, rc} ->
        {:error, classify_git_error(out, rc)}
    end
  end

  defp scan_secret_content(workspace, base_sha) do
    # `git log -p --unified=0` yields the diff OF EACH COMMIT individually (not the net) → a
    # secret introduced-then-removed carries its `+` line in the introduction commit. Only the ADDED
    # lines (`+`) count — we do not block on preexisting context.
    #
    # `--diff-merges=first-parent`: WITHOUT it, `git log -p` emits NO diff for a MERGE commit → a
    # secret introduced ONLY in the RESOLVED tree of an evil-merge (present in NEITHER parent) would
    # pass the scan and be pushed into the forge history. The option makes it emit, for each merge, the
    # delta vs its FIRST parent (= what the merge introduces into the mainline) → the `+` line of the
    # secret in the resolved tree becomes visible again. Does NOT alter the linear scan.
    case git(workspace, [
           "log",
           "-p",
           "--unified=0",
           "--diff-merges=first-parent",
           "--pretty=format:",
           "#{base_sha}..HEAD"
         ]) do
      {out, 0} ->
        added =
          out
          |> String.split("\n")
          |> Enum.filter(&(String.starts_with?(&1, "+") and not String.starts_with?(&1, "+++")))
          |> Enum.join("\n")

        case Enum.find_value(@secret_patterns, fn {re, kind} ->
               if Regex.match?(re, added), do: kind, else: nil
             end) do
          nil -> :ok
          kind -> {:error, {:secret_detected, kind, "diff added lines"}}
        end

      {out, rc} ->
        {:error, classify_git_error(out, rc)}
    end
  end

  # `git -C <ws> <args>` bounded (network push/diff or a big packfile do not block the GenServer).
  # Config neutralization — SINGLE SOURCE `Fleet.Credentials.Shell.git_safe_config_args/0` (hooks +
  # fsmonitor + sshCommand + diff.external + global attributesFile), composed on EVERY world-side git
  # invocation on a workspace co-written by the pod. LOAD-BEARING here: `scan_secrets` runs `git log -p`, which
  # executes a `diff.external`/textconv armed by the pod = arbitrary command execution on the world side at
  # the moment of the deliverable scan. The set's `diff.external=` disarms it (the other flags close hooks and
  # the like for uniformity, zero cost).
  @hooks_off Fleet.Credentials.Shell.git_safe_config_args()

  defp git(workspace, args) do
    # Bounded by `Fleet.Credentials.Shell.git/2` (setsid + SIGKILL of the OS process-GROUP at the deadline).
    # A `Task.async + Task.shutdown(:brutal_kill)` pattern would kill ONLY the BEAM Task
    # while letting the OS `git` process leak (a `git log -p` on a big diff exceeding 15 s leaves a
    # zombie holding FDs on the workspace; unbounded accumulation under concurrent gates). `@hooks_off`
    # stays composed HERE: Shell.git does NOT auto-compose the config neutralization (it is load-bearing —
    # anti-RCE `diff.external` on `git log -p`), the caller keeps it. External contract `{out, exit_code}`
    # preserved; the callers map the exit code via `classify_git_error/2`, which keeps the synthetic
    # rc 124 (timeout) DISTINCT from a hard git error. Runner injectable (`:deliverable_gate_git_runner`)
    # so a test can exercise the rc124 timeout path (a real Shell timeout is impractical to induce).
    runner =
      Application.get_env(
        :fleet_workflow,
        :deliverable_gate_git_runner,
        &Fleet.Credentials.Shell.git/2
      )

    case runner.(@hooks_off ++ ["-C", workspace] ++ args, timeout_ms: @git_timeout_ms) do
      {:ok, {out, code}} -> {out, code}
      {:error, {:timeout, ms}} -> {"git timeout (#{ms}ms)", 124}
      {:error, {:exit, reason}} -> {"git exec error: #{inspect(reason)}", 125}
      # TOTAL over the Shell error union (output_overflow, bad_opt, future members):
      # an unmatched member crashed the gate's owner instead of reading as a hard rc.
      {:error, reason} -> {"git shell error: #{inspect(reason)}", 125}
    end
  end

  # Maps a non-zero git exit code to a typed reason. The bounded `git/2` synthesizes rc 124 for a
  # Shell TIMEOUT (SIGKILL at the deadline) — that is NOT a hard git failure, and a caller/operator must
  # keep the distinction (a timeout is retry-worthy, a git_error is investigate-worthy). rc 125 (exec
  # error) and any real git rc are hard `:git_error`.
  defp classify_git_error(out, 124), do: {:git_timeout, String.trim(out)}
  defp classify_git_error(out, _rc), do: {:git_error, String.trim(out)}
end
