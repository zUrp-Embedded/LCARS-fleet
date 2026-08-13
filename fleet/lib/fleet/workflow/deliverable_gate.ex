defmodule Fleet.Workflow.DeliverableGate do
  @moduledoc """
  World-side gate before publication: base ancestry, commit identity/trailer, and
  per-commit secret scan. It trusts no pod assertion; any failure prevents push.
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
          # BL-6-16: an instruction-tier path (.claude/**, non-root CLAUDE.md) in the chain.
          | {:forbidden_path_in_diff, String.t()}
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

  # Payload mode has no producer-role trailer.
  defp maybe_check_trailer(_workspace, _base_sha, nil), do: :ok

  defp maybe_check_trailer(workspace, base_sha, role) when is_binary(role),
    do: check_coauthor_trailer(workspace, base_sha, role)

  @doc "Requires `base_sha` to be an ancestor of HEAD."
  @spec check_base_ancestor(Path.t(), String.t()) :: :ok | {:error, reason()}
  def check_base_ancestor(workspace, base_sha) do
    # Git owns rc classification; this gate shapes diagnostics.
    case Fleet.Workflow.Git.ancestor?(workspace, base_sha, "HEAD") do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        # Failure-only HEAD/parent detail distinguishes amend from a reset.
        {:error,
         {:base_not_ancestor,
          "#{String.slice(to_string(base_sha), 0, 12)} ⊄ HEAD=#{head_diag(workspace)}"}}

      {:error, {:git_timeout, _} = e} ->
        {:error, e}

      {:error, {:git_error, _} = e} ->
        {:error, e}

      # Unknown results remain hard git errors.
      {:error, other} ->
        {:error, {:git_error, "merge-base: #{inspect(other)}"}}
    end
  end

  # Best-effort failure diagnostic; it cannot replace the already-known result.
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

  # Split calls keep a root HEAD's absent parent from poisoning its own SHA.
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
  Requires each commit author and committer email to be allowed; empty range is valid.
  """
  @spec check_identity(Path.t(), String.t(), [String.t()]) :: :ok | {:error, reason()}
  def check_identity(workspace, base_sha, allowed) do
    case git(workspace, ["log", "#{base_sha}..HEAD", "--format=%ae%n%ce"]) do
      {out, 0} ->
        # Remove only the record terminator so empty identity fields remain rejectable.
        case out do
          "" ->
            :ok

          _ ->
            emails =
              out
              |> String.replace_suffix("\n", "")
              |> String.split("\n")
              |> Enum.map(&String.trim/1)

            allowed_set = MapSet.new(allowed)

            # Empty email is rejected and rendered readably in diagnostics.
            case Enum.reject(emails, &MapSet.member?(allowed_set, &1)) do
              [] -> :ok
              bad -> {:error, {:bad_identity, bad |> Enum.map(&label_email/1) |> Enum.uniq()}}
            end
        end

      {out, rc} ->
        {:error, classify_git_error(out, rc)}
    end
  end

  # Render rejected empty identity fields visibly.
  defp label_email(""), do: "<empty-email>"
  defp label_email(e), do: e

  @doc """
  Requires the expected `Co-authored-by: LCARS-<role>` trailer per commit.
  """
  @spec check_coauthor_trailer(Path.t(), String.t(), String.t()) :: :ok | {:error, reason()}
  def check_coauthor_trailer(workspace, base_sha, expected_role) when is_binary(expected_role) do
    # F-03: git parses real trailers; prose mentioning a trailer cannot attest a commit.
    needle =
      Fleet.Credentials.ForgeIdentity.coauthor_trailer(expected_role)
      |> String.replace_prefix("Co-authored-by: ", "")
      |> String.split(" <")
      |> hd()

    # NUL separates commits, unit separator splits SHA and trailer values.
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
              # One real trailer value must start with the expected role.
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
  Scans every commit's added content and filenames for secrets. Net-diff scanning
  would miss a secret committed then removed while publication still transfers it.
  """
  @spec scan_secrets(Path.t(), String.t()) :: :ok | {:error, reason()}
  def scan_secrets(workspace, base_sha) do
    with :ok <- scan_secret_filenames(workspace, base_sha) do
      scan_secret_content(workspace, base_sha)
    end
  end

  defp scan_secret_filenames(workspace, base_sha) do
    # Per-commit first-parent diffs include added-then-removed and merge-resolution files.
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

        # BL-6-16 second line (independent of the workspace sanitizer): instruction-tier paths
        # are FORBIDDEN in a deliverable chain — a commit touching `.claude/**` or a NON-root
        # `CLAUDE.md` would plant (or delete) directive material in the target repo at harvest.
        # Same per-commit listing as the secret scan below: zero extra git call. The ROOT
        # CLAUDE.md stays legitimate (a scribe may document the project).
        case Enum.find(files, &forbidden_instruction_path?/1) do
          nil ->
            case Enum.find(files, &Regex.match?(@secret_file_re, &1)) do
              nil -> :ok
              f -> {:error, {:secret_detected, "blacklisted_file", f}}
            end

          f ->
            {:error, {:forbidden_path_in_diff, f}}
        end

      {out, rc} ->
        {:error, classify_git_error(out, rc)}
    end
  end

  defp forbidden_instruction_path?(path) do
    segments = Path.split(path)
    ".claude" in segments or (Path.basename(path) == "CLAUDE.md" and length(segments) > 1)
  end

  defp scan_secret_content(workspace, base_sha) do
    # Per-commit first-parent diffs expose introduced-then-removed and merge secrets.
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

  # Every world-side git call is bounded and neutralizes pod-controlled config.
  @hooks_off Fleet.Credentials.Shell.git_safe_config_args()

  defp git(workspace, args) do
    # Shell kills the git process group at the deadline; timeout remains distinct from git failure.
    runner =
      Application.get_env(
        :lcars_fleet,
        :workflow_deliverable_gate_git_runner,
        &Fleet.Credentials.Shell.git/2
      )

    case runner.(@hooks_off ++ ["-C", workspace] ++ args, timeout_ms: @git_timeout_ms) do
      {:ok, {out, code}} -> {out, code}
      {:error, {:timeout, ms}} -> {"git timeout (#{ms}ms)", 124}
      {:error, {:exit, reason}} -> {"git exec error: #{inspect(reason)}", 125}
      # Preserve future Shell errors as hard git failures.
      {:error, reason} -> {"git shell error: #{inspect(reason)}", 125}
    end
  end

  # Synthetic rc 124 denotes timeout; all other nonzero codes are git errors.
  defp classify_git_error(out, 124), do: {:git_timeout, String.trim(out)}
  defp classify_git_error(out, _rc), do: {:git_error, String.trim(out)}
end
