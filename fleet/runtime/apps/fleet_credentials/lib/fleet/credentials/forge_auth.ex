defmodule Fleet.Credentials.ForgeAuth do
  @moduledoc """
  System-side git auth for private forge ops (clone / fetch / ls-remote / push). SINGLE source:
  this helper has one owner here rather than a byte-for-byte duplicate in `Fleet.Workflow.Git` AND
  `Fleet.ProjectBootstrap.Phase.Clone` — the `workflow ⇄ bootstrap` compile cycle forbids sharing
  between them. `fleet_credentials` sits below both (common dependency) → the right owner; and
  the forge token IS a credential.

  ## Secret kept off the argv

  The token (`%{url_prefix, token}` under `:fleet_credentials, :forge_auth`, set at boot from
  the env/secret) is injected via the **ENVIRONMENT** variables `GIT_CONFIG_COUNT` /
  `GIT_CONFIG_KEY_n` / `GIT_CONFIG_VALUE_n` (git ≥ 2.31), **not** on the argv. Passing the token via
  `-c http.<prefix>.extraheader=Authorization: token <T>` would expose it in
  `/proc/<pid>/cmdline` — **world-readable**: a process of ANOTHER human on the host would read it via
  `ps`. The environ (`/proc/<pid>/environ`) is mode 0400 owner-only. Git applies the env-config
  exactly like `-c` (verified git 2.43). Never persisted into the workspace's `.git/config` → the
  pod inherits a remote WITHOUT credential (forge-blind barrier).

  ## Usage

      System.cmd("git", ["clone", url, dst], env: Fleet.Credentials.ForgeAuth.git_env())

  The secret then lives in the environ of the **child git process** (short-lived), never in the
  BEAM's (`System.cmd env:` touches only the child). Not configured (local repo `file://`, mirror) →
  just `[@git_no_prompt]` (the unconditional anti-prompt bound), no forge auth header added.
  """

  # `GIT_TERMINAL_PROMPT=0` set UNCONDITIONALLY in the single source of the git env. Without it,
  # an absent/expired token (or a repo that demands an auth we don't have) makes git OPEN AN interactive
  # PROMPT (username/password); launched by the BEAM WITHOUT a TTY, the prompt HANGS indefinitely → the
  # git process never returns → the calling GenServer (Pod, Poller) stays frozen on `System.cmd`. The
  # `0` bound forces git to FAIL immediately (rc≠0) instead of prompting — the typed error propagates up
  # and the bounded wrapper (`Fleet.Credentials.Shell.run/2`) can kill it within its timeout. Set even
  # when `forge_auth` is NOT configured (local repo `file://`): that is precisely the case where the
  # absence of credential would trigger the prompt. Covers ALL call-sites going through `git_env()`.
  require Logger

  @git_no_prompt {"GIT_TERMINAL_PROMPT", "0"}

  @doc """
  Environment variables for the system-side git auth — `[{name, value}]` to pass as-is to
  `System.cmd(env:)`. **ALWAYS carries `GIT_TERMINAL_PROMPT=0`** (anti-hang bound);
  adds the forge auth extraheader IF `:fleet_credentials, :forge_auth` is present and complete.
  Never `[]` (the anti-prompt invariant is unconditional).
  """
  @spec git_env() :: [{String.t(), String.t()}]
  def git_env do
    case Application.get_env(:fleet_credentials, :forge_auth) do
      nil ->
        # ABSENT = a fleet with no forge configured (tests, local-only `file://`) → anti-prompt only, no
        # noise. This is the legitimate "no auth" state (distinct from a present-but-broken config below).
        [@git_no_prompt]

      %{url_prefix: prefix, token: token}
      when is_binary(prefix) and is_binary(token) and prefix != "" and token != "" ->
        if safe_prefix?(prefix) do
          [
            @git_no_prompt,
            {"GIT_CONFIG_COUNT", "1"},
            {"GIT_CONFIG_KEY_0", "http.#{prefix}.extraheader"},
            {"GIT_CONFIG_VALUE_0", "Authorization: token #{token}"}
          ]
        else
          # R1-15: a newline/control char in `url_prefix` would inject a parasite git-config key. Refuse
          # the header (never `inspect` the value — it sits next to the token). LOUD, not silent.
          Logger.error(
            "ForgeAuth: :forge_auth url_prefix carries a newline/control char — auth header SKIPPED " <>
              "(git ops UNAUTHENTICATED). Fix the forge config."
          )

          [@git_no_prompt]
        end

      _other ->
        # PRESENT but malformed (empty/missing url_prefix or token, wrong shape): do NOT swallow silently
        # (MINE-CRED-01). Otherwise git runs UNAUTHENTICATED and only fails later at the remote (403/404),
        # masking the real cause = the broken credential config. LOUD (no `inspect` — a token may be inside).
        Logger.error(
          "ForgeAuth: :forge_auth is PRESENT but malformed (empty/missing url_prefix or token) — auth " <>
            "header SKIPPED (git ops UNAUTHENTICATED). Fix the forge config."
        )

        [@git_no_prompt]
    end
  end

  # `url_prefix` is interpolated into the git-config key `http.<prefix>.extraheader`: a control char
  # (esp. newline) would inject a parasite config line. NOT the full URL authority — a guardrail.
  defp safe_prefix?(prefix), do: not String.match?(prefix, ~r/[\x00-\x1F\x7F]/)
end
