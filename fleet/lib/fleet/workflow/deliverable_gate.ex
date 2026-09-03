defmodule Fleet.Workflow.DeliverableGate do
  @moduledoc """
  World-side gate before publication: base ancestry, commit identity/trailer, and
  per-commit secret scan. It trusts no pod assertion; any failure prevents push.

  The first three checks are DECIDABLE -- an ancestry either holds or it does not. The secret scan
  is not: it matches known credential shapes on added text (see `scan_secrets/2` for the scope and
  what falls outside it). Passing it is the absence of a known shape, never a clean bill; the
  credential rails, not this scan, are what keep the fleet's own tokens out of a workspace.
  """

  @git_timeout_ms 15_000

  # WHAT THIS SCAN IS, AND WHAT IT IS NOT. It is a filter on credential shapes that ANNOUNCE
  # themselves: a fixed prefix or header long enough that a match is a secret rather than a
  # coincidence. It is NOT a proof that the diff carries no credential, and it must never be read
  # as one -- `:ok` here means "no known shape was seen", not "clean".
  #
  # The line is drawn at the false-positive cost, and it is not adjustable by taste: this gate
  # BLOCKS a push. A pattern that fires on legitimate content turns the publication path into a
  # wall, and the pods have no way around it.
  #
  # ⚠ THE CREDENTIAL THIS FLEET ACTUALLY HANDLES IS THE ONE THAT CANNOT BE MATCHED. A Gitea token
  # is 40 hex characters with no prefix -- the exact shape of every git SHA in every diff, so a
  # pattern for it would refuse nearly every commit. It is held out of diffs by the credential
  # rails (never in argv, never in a workspace file), not by this scan, and writing that down is
  # the only honest thing to do about it. Same for a plaintext password or a connection string:
  # shapeless, hence out of reach here.
  @secret_patterns [
    {~r/sk-ant-[A-Za-z0-9_\-]{8,}/, "anthropic_key"},
    # The pod's OAuth token is a JWT `eyJ...`.
    {~r/eyJ[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{10,}/, "jwt_token"},
    {~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/, "private_key"},
    {~r/AKIA[0-9A-Z]{16}/, "aws_access_key"},
    # ⚠ ONE FORGE PREFIX IS NOT THE SHAPE WE USE OURSELVES. GitHub documents six (`ghp_` classic,
    # `github_pat_` fine-grained, `gho_` OAuth, `ghu_` user-to-server, `ghs_` installation, `ghr_`
    # refresh), and `gho_` is precisely what `gh auth status` reports on a machine where the
    # operator ran `gh auth login`: a gate carrying `ghp_` alone would not recognise the credential
    # of its own tooling. GitLab needs its own — this fleet announces it as a first-class forge on
    # BOTH the import and the export side, so a `glpat-` travels through without a word.
    #
    # THE BODY LENGTH IS A FLOOR, NOT A COUNT. `{36}` would encode the classic format as if it were
    # the only one; GitHub shipped a stateless `ghs_APPID_JWT` form on 2026-04-27 warning that
    # anything assuming a fixed length will mishandle it. `{20,}` refuses the same secrets and
    # survives the next format.
    {~r/gh[pousr]_[A-Za-z0-9]{20,}/, "github_token"},
    {~r/github_pat_[A-Za-z0-9_]{20,}/, "github_pat_fine_grained"},
    {~r/glpat-[A-Za-z0-9_\-]{20,}/, "gitlab_pat"},
    {~r/gloas-[A-Za-z0-9_\-]{20,}/, "gitlab_oauth_secret"},
    {~r/xox[baprs]-[A-Za-z0-9\-]{10,}/, "slack_token"},
    {~r/AIza[0-9A-Za-z_\-]{35}/, "google_api_key"}
  ]

  # Files forbidden in a diff (creds/secrets by name). Match on basename.
  @secret_file_re ~r/(^|\/)(\.credentials\.json|\.env(\..+)?|\.netrc|\.tok|id_rsa.*|.*\.pem|.*\.key)$/

  @type reason ::
          {:base_not_ancestor, String.t()}
          | {:bad_identity, [String.t()]}
          | {:missing_coauthor_trailer, String.t(), [String.t()]}
          | {:secret_detected, String.t(), String.t()}
          # A GOVERNANCE path in the chain: instruction-tier (BL-6-16 — `.claude/**`, non-root
          # `CLAUDE.md`) or the project declaration (`.lcars.json` at the root).
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
  Requires each FIRST-PARENT commit author and committer email to be allowed; empty range is valid.
  """
  # A0 — FIRST-PARENT, same cut as the secret scan below, and any asymmetry between the two is a
  # defect: a conflict resolution is a MERGE commit, so the full `base..HEAD` range imports the
  # BASE's own commits — system-authored onboard writes, sibling bricks trailed by OTHER roles —
  # all already gated when they landed on the base. Re-walking them here refuses EVERY merge-bearing
  # deliverable on `{:bad_identity, …}`, leaving the chief's exception pass with no success path at
  # all. The pod's own line IS the first-parent line; the merge commit itself sits on it, authored
  # by the pod's human and hook-trailed, and stays fully checked.
  @spec check_identity(Path.t(), String.t(), [String.t()]) :: :ok | {:error, reason()}
  def check_identity(workspace, base_sha, allowed) do
    case git(workspace, ["log", "--first-parent", "#{base_sha}..HEAD", "--format=%ae%n%ce"]) do
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
  Requires the expected `Co-authored-by: LCARS-<role>` trailer per FIRST-PARENT commit.
  """
  # FIRST-PARENT for the same reason as `check_identity` above: a merge imports commits trailed
  # by their OWN producers, so demanding THIS role's trailer on a sibling brick's commit refuses
  # the range wholesale (`{:missing_coauthor_trailer}`). The pod's own commits stay checked.
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
           "--first-parent",
           "#{base_sha}..HEAD",
           "--format=%H%x1f%(trailers:key=Co-authored-by,valueonly)%x00"
         ]) do
      {out, 0} ->
        missing =
          out
          |> String.split(<<0>>, trim: true)
          |> Enum.flat_map(&uncovered_sha(&1, needle))

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

  SCOPE, because `:ok` here authorizes a push: known credential SHAPES on lines the diff renders
  as ADDED text, plus a blacklist of filenames. Three things are therefore outside it by
  construction -- a credential with no distinctive shape (a Gitea token is 40 hex, like every SHA
  in the diff; a password; a connection string), a secret inside a file git does not render as
  text, and any content the diff does not present as an addition. `:ok` means no known shape was
  seen; it never means the chain is clean.
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

        # BL-6-16 second line (independent of the workspace sanitizer): GOVERNANCE paths are
        # FORBIDDEN in a deliverable chain — a commit touching `.claude/**` or a NON-root
        # `CLAUDE.md` would plant (or delete) directive material in the target repo at harvest.
        # Same per-commit listing as the secret scan below: zero extra git call. The ROOT
        # CLAUDE.md stays legitimate (a scribe may document the project).
        case Enum.find(files, &forbidden_governance_path?/1) do
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

  # LA REGLE EST « UN PRODUCTEUR NE MODIFIE PAS CE QUI LE GOUVERNE », et elle a deux objets.
  #
  # Le premier est l'etage INSTRUCTION (BL-6-16) : `.claude/**` et un `CLAUDE.md` NON-racine
  # planteraient de la matiere directive dans le depot cible. Le `CLAUDE.md` RACINE reste legitime —
  # un scribe documente son projet.
  #
  # Le second est la DECLARATION DU PROJET, `.lcars.json` a la racine, et il demande de mettre deux
  # faits cote a cote : ce fichier porte `pipeline_default`, c'est-a-dire QUELLE CARTE route le
  # ticket — donc quel jury, quelles portes, quel CI — et il est lu a chaud par `StepDispatcher`
  # (`Declaration.pipeline_default/2`) depuis la face code, alignee sur `main` apres merge. Sans ce
  # chemin dans la liste, un producteur le reecrit dans son espace de travail, le commite, et la
  # porte laisse passer : elle verifie l'ancetre, l'identite, le trailer et les secrets, jamais ce
  # fichier. Basculer la declaration vers une carte `jury: []` / `ci: ignore` fait tomber les juges
  # du ticket SUIVANT, et la seule chose qui reste alors entre l'agent et ce resultat est qu'un
  # relecteur remarque le diff — exactement la garantie qu'un plancher mecanique existe pour ne pas
  # avoir a demander.
  #
  # ⚠ Uniquement A LA RACINE, et c'est deliberе : rien ne lit un `.lcars.json` plus profond, et
  # interdire un chemin que personne ne lit est une regle que le prochain lecteur ne saura pas
  # justifier. Symetrie inverse de `CLAUDE.md` (racine permise, profond interdit) parce que les deux
  # fichiers sont load-bearing a des endroits opposes de l'arbre.
  #
  # L'HUMAIN, LUI, N'EST PAS BORNE PAR CETTE PORTE : il possede le depot et edite la declaration
  # directement. Ce garde ne parle que d'une chaine de livraison produite par un pod.
  defp forbidden_governance_path?(path) do
    segments = Path.split(path)

    ".claude" in segments or
      (Path.basename(path) == "CLAUDE.md" and length(segments) > 1) or
      segments == [Fleet.Layout.project_declaration_file()]
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

        refuse_secret(added, "diff added lines")

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

  # La premiere forme de secret reconnue dans un texte, ou `:ok`. Le NOM de la forme voyage avec le
  # refus : « un secret » sans dire lequel envoie l'auteur relire tout son diff.
  defp refuse_secret(texte, ou) do
    case Enum.find_value(@secret_patterns, fn {re, kind} ->
           if Regex.match?(re, texte), do: kind, else: nil
         end) do
      nil -> :ok
      kind -> {:error, {:secret_detected, kind, ou}}
    end
  end

  # Le sha d'un commit dont AUCUNE valeur de trailer ne commence par le role attendu. Un chunk sans
  # separateur n'a pas de trailer du tout : il ne prouve rien, donc il n'accuse rien.
  defp uncovered_sha(chunk, needle) do
    case String.split(chunk, <<0x1F>>, parts: 2) do
      [sha, values] ->
        couvert? =
          values
          |> String.split("\n", trim: true)
          |> Enum.any?(&(String.trim_leading(&1) |> String.starts_with?(needle)))

        if couvert?, do: [], else: [String.trim(sha)]

      _ ->
        []
    end
  end

  # Synthetic rc 124 denotes timeout; all other nonzero codes are git errors.
  defp classify_git_error(out, 124), do: {:git_timeout, String.trim(out)}
  defp classify_git_error(out, _rc), do: {:git_error, String.trim(out)}
end
