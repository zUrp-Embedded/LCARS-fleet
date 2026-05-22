defmodule Fleet.ClaudeBridge.SPInjection do
  @moduledoc """
  Build flags `claude -p` `--system-prompt-file` + `--append-system-prompt-file`
  cohérents `fleet_spbuilder` chantier 2 (N2 / N2bis).

  Consommé indirectement par `bin/claude_launch.sh` (chantier 5
  PROMOTED) via env vars + paths résolus côté `Fleet.Spawner.Pod`
  phase PROJECT (chantier 6 PROMOTED).

  Pas d'invocation directe SDK ici — pure data transformer
  (cap-profile + paths → flags list).
  """

  @doc """
  Construit la liste des flags `claude -p` à partir d'un cap-profile
  + paths SP/brief.

  ## Inputs

    * `cap_profile` — `%Fleet.CapProfile{}`
    * `opts` :
      * `:sp_path` (obligatoire) — path absolu `system-prompt.md` (N2)
      * `:brief_path` (optionnel) — path absolu `brief.md` (N2bis)
      * `:budget_usd` (optionnel) — string ou number

  ## Returns

  Liste de flags string (ex `["--system-prompt-file", "/path/sp.md", ...]`).

  ## Examples

      iex> profile = %Fleet.CapProfile{
      ...>   api_version: "lcars/v2.5",
      ...>   kind: "CapabilityProfile",
      ...>   metadata: %{"name" => "engineer"},
      ...>   spec: %{
      ...>     "scope" => %{
      ...>       "allowedTools" => ["Read", "Glob"],
      ...>       "disallowedTools" => ["web_search"]
      ...>     }
      ...>   }
      ...> }
      iex> flags = Fleet.ClaudeBridge.SPInjection.build_flags(profile,
      ...>   sp_path: "/tmp/sp.md", brief_path: "/tmp/brief.md", budget_usd: 1.0)
      iex> "--system-prompt-file" in flags
      true
      iex> "/tmp/sp.md" in flags
      true
      iex> "--allowedTools" in flags
      true
  """
  @spec build_flags(Fleet.CapProfile.t(), keyword()) :: [String.t()]
  def build_flags(%Fleet.CapProfile{} = cap_profile, opts) when is_list(opts) do
    sp_path = Keyword.fetch!(opts, :sp_path)
    brief_path = Keyword.get(opts, :brief_path)
    budget_usd = opts |> Keyword.get(:budget_usd, "1.0") |> validate_budget!()

    allowed = get_in(cap_profile.spec, ["scope", "allowedTools"]) || []
    disallowed = get_in(cap_profile.spec, ["scope", "disallowedTools"]) || []

    base = [
      "--output-format",
      "stream-json",
      "--verbose",
      "--system-prompt-file",
      sp_path
    ]

    base
    |> maybe_append_brief(brief_path)
    |> append_tools_lists(allowed, disallowed)
    |> Kernel.++(["--max-budget-usd", budget_usd])
  end

  @doc """
  Build flags mode-aware (DN ring1/fleet_claude_bridge.md §amendement RCMode).
  **Additif** : `build_flags/2` (cap-profile `claude -p` chantier-8) inchangé.

  - `:print` — `--system-prompt-file` (+ `--append-system-prompt-file`)
  - `:remote_control` — `remote-control --spawn=session --system-prompt-file`
    (+ `--name`/`--resume`/`--append-system-prompt-file` conditionnels)

  Clés `:name`/`:resume` (alignées DN test 7 conformance — normatif — et
  `RCMode.build_rc_args/1` ; le pseudo-code DN L434-435 disait
  `:session_name`/`:resume_session_id` = illustratif, le test fait foi).

      iex> Fleet.ClaudeBridge.SPInjection.build_flags(:remote_control, "/sp.md",
      ...>   name: "architect", resume: "abc123")
      ["remote-control", "--spawn=session", "--system-prompt-file", "/sp.md",
       "--name", "architect", "--resume", "abc123"]
  """
  @spec build_flags(:print | :remote_control, Path.t(), keyword()) :: [String.t()]
  def build_flags(:print, sp_path, opts)
      when is_binary(sp_path) and is_list(opts) do
    ["--system-prompt-file", sp_path]
    |> maybe_arg("--append-system-prompt-file", opts[:append_sp_path])
  end

  def build_flags(:remote_control, sp_path, opts)
      when is_binary(sp_path) and is_list(opts) do
    ["remote-control", "--spawn=session", "--system-prompt-file", sp_path]
    |> maybe_arg("--name", opts[:name])
    |> maybe_arg("--resume", opts[:resume])
    |> maybe_arg("--append-system-prompt-file", opts[:append_sp_path])
  end

  defp maybe_arg(flags, _flag, nil), do: flags
  defp maybe_arg(flags, _flag, ""), do: flags
  defp maybe_arg(flags, flag, val) when is_binary(val), do: flags ++ [flag, val]

  defp maybe_append_brief(flags, nil), do: flags

  defp maybe_append_brief(flags, brief_path) when is_binary(brief_path) do
    flags ++ ["--append-system-prompt-file", brief_path]
  end

  defp append_tools_lists(flags, allowed, disallowed) do
    flags
    |> Kernel.++(["--allowedTools", Enum.join(allowed, ",")])
    |> Kernel.++(["--disallowedTools", Enum.join(disallowed, ",")])
  end

  defp validate_budget!(v) when is_number(v) or is_binary(v), do: to_string(v)

  defp validate_budget!(v),
    do: raise(ArgumentError, "budget_usd doit être number|binary, reçu: #{inspect(v)}")
end
