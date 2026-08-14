defmodule Fleet.Credentials.ForgeIdentity do
  @moduledoc """
  Resolves the git identity of a deliverable: **author = the human
  of the brief**, the LCARS role being carried by a **verified** trailer `Co-authored-by:
  LCARS-<role>` (non-negotiable: the identity is NEVER flattened onto a shared account;
  the machine signature is a verified trailer, not the author).

  ## Where the human comes from

  The human of the brief = **the user of the runtime process** (`id -un`): the ENTIRE
  fleet runs under the OS user of the human who launches it (the human runs `bin/fleet_v2`,
  the BEAM inherits their UID — no systemd `User=` directive) — each human = their fleet
  under their user, OS isolation by construction; the pod (BEAM Port) inherits this UID.
  So the current user IS the human. No literal default (it would mask a wiring hole):
  `id -un` unresolvable → fail-loud.

  ## Where its git name/email comes from — the OS, not a catalogue

  **If the user exists on the system, it is a human of the fleet** — no re-filtering
  through a catalogue. The git identity is DERIVED from the OS, in order:

    * **name**  : `git config --global user.name` (the daemon runs *as* the human → reads
      their `~/.gitconfig`, the identity it ALREADY commits with) → otherwise GECOS
      (`getent passwd`) → otherwise the login.
    * **email** : `git config --global user.email` → otherwise `<login>@<hostname>`
      (git's default convention).

  No file read, no knob to provision, no fail-loud "human absent from the
  catalogue": an OS user ⇒ always an identity. (Test seam: `opts[:identity]`
  or `config :lcars_fleet, :credentials_forge_identity_override` — `git config` varies per runner.)

  **Nominal deployment prerequisite**: the human has `git config --global user.email` configured.
  Otherwise the `<login>@<hostname>` fallback is NOT stable — the email is resolved
  twice independently (at spawn → the pod's `GIT_AUTHOR_EMAIL`; at check → the `allowed_emails`
  of the commit-identity gate); if the gitconfig is completed or the hostname changes between the two,
  the emails diverge and the gate rejects a legitimate commit. With `git config user.email` set, stable.

  ## Role trailer

  `Co-authored-by: LCARS-<role> <<role>@lcars.local>` — the trailer is what the commit-identity
  gate verifies (presence + role ↔ step). A pure string, mechanically verifiable.

  ## allowed_emails (commit-identity gate)

    * `git_native` — the pod commits AS the human → author=committer=human →
      `[human_email]`.
    * `payload` — the SYSTEM commits (author=human, committer=system) →
      `[human_email, system_email()]`.

  ## Deliberately NOT split — gate policy stays in this module

  `allowed_emails/2` + `system_email/0` (consumed at CHECK time by the commit
  gate) have a different consumer/moment from the rest (consumed at SPAWN time),
  yet both faces derive from the SAME identity literals (`@system_email`,
  `@role_email_domain` — `system_email` feeds `allowed_emails` on the check side
  AND `system_identity` on the spawn side; `role_email` feeds the trailer).
  Separating them = either duplicating a literal (two authorities → the exact
  divergence this module exists to forbid — no caller composes a git email by
  hand), or an inter-module dep for 4 lines. The forge-identity domain is ONE
  boundary; spawn and check are its two moments, not two concerns.

  ## Identity destination

  These identities are those of the LOCAL FORGE (real role accounts, emails mapped → avatars/traceability).
  The domain is a WIRE CONTRACT shared with `bwrap_launch.sh` (which sets GIT_AUTHOR/COMMITTER to the
  HUMAN of the brief in env at launch — cf. its Z4 identity block; the role rides the `Co-authored-by:
  <role>@lcars.local` TRAILER, never the author) — a divergence is caught STRUCTURALLY by the
  commit-identity gate (push rejected fail-closed).

  GitHub PUBLISH: the LCARS role steps aside at publish, the CO-AUTHOR becomes THE
  VENDOR (not a role, never hardcoded — Claude today, another vendor tomorrow), derived from the
  fact co-located with the active N1 launcher (`bin/<vendor>_launch.identity`, cf.
  `bin/claude_launch.identity`) — same discipline as the N0/N1 vendor boundary. The AUTHOR becomes
  the human (the system steps aside too: `author := committer` on `system_email()` commits). The
  rewrite itself lives outside Elixir (`bin/publish-to-github.sh`, `git filter-repo`): this module
  stays the authority for the LOCAL forge identities, not the executor of the publish transformation.
  """

  @role_email_domain "lcars.local"
  @system_name "lcars-system"
  # Real SYSTEM forge account: `lcars-system@lcars.local` commits map to the `lcars-system`
  # forge account (avatar/traceability active). ONE system identity, defined HERE only.
  @system_email "#{@system_name}@#{@role_email_domain}"

  @type identity :: %{
          author_name: String.t(),
          author_email: String.t(),
          committer_name: String.t(),
          committer_email: String.t(),
          human: String.t(),
          role: String.t(),
          coauthor_trailer: String.t()
        }

  @doc """
  Resolves the complete human identity and role trailer. `:human` overrides the runtime
  user and `:identity` injects a name/email pair without OS lookup.
  """
  @spec for_role(String.t(), keyword()) :: {:ok, identity()} | {:error, term()}
  def for_role(role, opts \\ []) when is_binary(role) and role != "" do
    with {:ok, %{name: name, email: email, human: human}} <- resolve_identity(opts) do
      {:ok,
       %{
         author_name: name,
         author_email: email,
         committer_name: name,
         committer_email: email,
         human: human,
         role: role,
         coauthor_trailer: coauthor_trailer(role)
       }}
    end
  end

  @doc """
  Resolves the runtime human's name, email and login. Options match `for_role/2`.
  """
  @spec human_identity(keyword()) ::
          {:ok, %{name: String.t(), email: String.t(), human: String.t()}} | {:error, term()}
  def human_identity(opts \\ []), do: resolve_identity(opts)

  @doc "Machine-verifiable trailer for the role (canonical Co-authored-by). Derives from `role_email/1`."
  @spec coauthor_trailer(String.t()) :: String.t()
  def coauthor_trailer(role) when is_binary(role) do
    # F-C018 — `role` (= cap-profile `metadata.name`, a schema-OPEN field, no pattern) is interpolated into
    # the trailer + role email that land in commit headers. A newline/control char would inject a commit-header
    # line (R1-14) — the exact defense the human name/email already get via `strip_control` (`os_identity/2`).
    # We apply the SAME hygiene to the role here (sink-side, source-agnostic). No-op on the clean canon slugs.
    clean = strip_control(role)
    "Co-authored-by: LCARS-#{clean} <#{role_email(clean)}>"
  end

  @doc """
  Identity emails accepted by the commit-identity gate depending on the mode. `git_native` → the human
  alone (they commit); `payload` → the human (author) + system (committer).
  """
  @spec allowed_emails(:git_native | :payload, String.t()) :: [String.t()]
  def allowed_emails(:git_native, human_email), do: [human_email]
  def allowed_emails(:payload, human_email), do: [human_email, @system_email]

  @doc """
  System identity (committer in payload mode). The system IS NOT the human: it
  materializes the commit, the author stays the human.
  """
  @spec system_email() :: String.t()
  def system_email, do: @system_email

  @doc """
  Complete git identity of the SYSTEM (`%{name, email}`) — author of commits generated by the runtime
  itself (e.g. onboarding scaffold). SINGLE accessor: do not re-type name/email at the caller.
  """
  @spec system_identity() :: %{name: String.t(), email: String.t()}
  def system_identity, do: %{name: @system_name, email: @system_email}

  @doc """
  Canonical git email of a `role` (`<role>@lcars.local`) — the SAME as the trailer's
  (`coauthor_trailer/1` derives from it) and the one set in env by the launcher. SINGLE accessor
  for the domain: no caller composes `@lcars.local` by hand.
  """
  @spec role_email(String.t()) :: String.t()
  def role_email(role) when is_binary(role) and role != "",
    # Strip control chars from `role` before it enters the email (commit-header sink),
    # same hygiene as the human identity fields. No-op on the clean canon slugs.
    do: "#{strip_control(role)}@#{@role_email_domain}"

  # ── internals ──

  defp resolve_human(opts) do
    case Keyword.get(opts, :human) do
      h when is_binary(h) and h != "" ->
        {:ok, h}

      # SINGLE source `Fleet.Credentials.Human` (never a second `id -un` shelled out).
      _ ->
        Fleet.Credentials.Human.current()
    end
  end

  # Resolves {name, email, human}. The `:forge_identity_override` config override (a
  # %{name, email, human?} map) short-circuits EVERYTHING (test seam: `id -un`/`git config`
  # vary per runner). An explicit `:identity` (forge_identity_test) disables
  # the override to test the REAL assembly. Otherwise: human (`id -un`) → OS identity.
  defp resolve_identity(opts) do
    override = Application.get_env(:lcars_fleet, :credentials_forge_identity_override)
    explicit_identity? = Keyword.has_key?(opts, :identity)

    case override do
      %{name: name, email: email} = ov
      when is_binary(name) and is_binary(email) and not explicit_identity? ->
        {:ok, %{name: name, email: email, human: Map.get(ov, :human, "override")}}

      _ ->
        with {:ok, human} <- resolve_human(opts) do
          {:ok, id} = os_identity(human, opts)
          {:ok, Map.put(id, :human, human)}
        end
    end
  end

  defp os_identity(human, opts) do
    case Keyword.get(opts, :identity) do
      %{name: name, email: email} when is_binary(name) and is_binary(email) ->
        {:ok, %{name: strip_control(name), email: strip_control(email)}}

      _ ->
        name =
          sanitize_identity(git_config("user.name")) || sanitize_identity(gecos_name(human)) ||
            human

        email = sanitize_identity(git_config("user.email")) || "#{human}@#{hostname()}"
        {:ok, %{name: name, email: email}}
    end
  end

  defp strip_control(s) when is_binary(s), do: String.replace(s, ~r/[\x00-\x1F\x7F]/, "")

  defp sanitize_identity(nil), do: nil

  defp sanitize_identity(s) when is_binary(s),
    do: s |> strip_control() |> String.trim() |> blank_to_nil()

  defp git_config(key) do
    case Fleet.Credentials.Shell.run("git", ["config", "--global", "--get", key],
           timeout_ms: 5_000
         ) do
      {:ok, {out, 0}} -> blank_to_nil(String.trim(out))
      _ -> nil
    end
  end

  defp gecos_name(human) do
    case Fleet.Credentials.Shell.run("getent", ["passwd", human], timeout_ms: 5_000) do
      {:ok, {line, 0}} ->
        line
        |> String.trim()
        |> String.split(":")
        |> Enum.at(4, "")
        |> String.split(",")
        |> List.first()
        |> blank_to_nil()

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp hostname do
    {:ok, h} = :inet.gethostname()
    List.to_string(h)
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s) when is_binary(s), do: s
end
