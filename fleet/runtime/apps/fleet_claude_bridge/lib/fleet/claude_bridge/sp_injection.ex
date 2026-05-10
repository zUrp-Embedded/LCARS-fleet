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
