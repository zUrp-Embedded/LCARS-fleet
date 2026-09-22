defmodule Fleet.Toolchain do
  use Boundary, deps: [Fleet.Labels], exports: []

  @moduledoc """
  Renders toolchain requests and their forge correlation keys for MCP and the reconciler.
  Callers open a PR containing the rendered manifest; human approval precedes reconciliation
  and privileged convergence. This module neither calls the forge nor installs tools.

  ⚠ THIS RAIL SERVES PODS, NOT CI. A pod is sandboxed and reaches the network through an egress
  proxy: an agent cannot download its own toolchain, which is why a privileged, human-approved
  gesture exists at all. A CI job has network — it declares its toolchain with a setup action
  (`erlef/setup-beam`, `actions/setup-*`), the way every forge does it. That the rail does not
  reach the runner is the separation working, not a gap to close.

  `ecosystem` identifies the manifest; `evidence` explains the request to the human approver.
  MCP supplies the input schema, while `validate_form/1` separately requires one of apt
  (container packages), installer (SDK store), or sysroot (target tree). Combining forms
  would bundle distinct effects and leave their execution order unspecified.
  """

  alias Fleet.Labels

  @forms ~w(apt installer sysroot)

  @typedoc "Request map supplied by MCP; field validation is external to this type."
  @type request :: map()

  @doc """
  Renders YAML in stable key order, preserving list order so retries produce reviewable diffs.
  Evidence appears last as a literal block for the human approver. Call `validate_form/1` first;
  rendering itself selects the first map-valued form and does not validate field contents.
  This renderer does not escape quotes, backslashes or newlines in ordinary scalar fields.
  """
  @spec render(request(), keyword()) :: String.t()
  def render(req, meta \\ []) when is_map(req) do
    [
      "# Généré par le rail toolchain — NE PAS ÉDITER À LA MAIN.",
      "# Ce que tu approuves en mergeant : le convergeur appliquera EXACTEMENT ce document,",
      "# au SHA de ce merge, sur tous les conteneurs qui suivent cette branche.",
      "kind: ecosystem_enable",
      "ecosystem: #{yaml_scalar(req["ecosystem"])}",
      form_block(req),
      hosts_block(req["egress_hosts"]),
      requested_by_block(meta),
      evidence_block(req["evidence"])
    ]
    |> Enum.reject(&(&1 == nil))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  @doc """
  Requires exactly one map-valued apt, installer or sysroot field. The current wire schema
  leaves this exclusivity check to the caller; choosing a form silently would change the request.
  """
  @spec validate_form(request()) :: :ok | {:error, {:toolchain_form, String.t()}}
  def validate_form(req) when is_map(req) do
    case Enum.filter(@forms, &is_map(req[&1])) do
      [_one] ->
        :ok

      [] ->
        {:error,
         {:toolchain_form,
          "aucune forme déclarée — il en faut exactement une parmi #{Enum.join(@forms, ", ")}"}}

      many ->
        {:error,
         {:toolchain_form,
          "#{length(many)} formes déclarées (#{Enum.join(many, ", ")}) — il en faut exactement " <>
            "une : elles agissent sur des endroits différents, et deux dans un même diff feraient " <>
            "approuver un effet pour un autre"}}
    end
  end

  # Request branches are a named family on the system repo, and the ONLY branches the runtime ever
  # creates there; the reconciler deletes them once their PR is merged or refused. A `/` after the
  # protected name is impossible in git (a ref cannot be both a file and a directory), hence `-`.
  @request_prefix "tool_request-"

  @doc """
  The request branch name for a work item — stable, so a retry lands on the SAME branch instead of
  opening a second pull request for one need.
  """
  @spec branch_for(String.t()) :: String.t()
  def branch_for(work_item_id) when is_binary(work_item_id),
    do: @request_prefix <> slug(work_item_id)

  @doc """
  True for a branch of the request family — what the reconciler may delete once drained. Never
  the protected branch itself, never a branch of another family.
  """
  @spec request_branch?(String.t()) :: boolean()
  def request_branch?(name) when is_binary(name),
    do: String.starts_with?(name, @request_prefix) and name != @request_prefix

  @doc """
  Stable branch for a request without a work item, using a pod-specific prefix.
  The prefix distinguishes equal pod/work-item slugs; it does not guarantee uniqueness for
  arbitrary inputs (a work-item slug beginning with `pod-` can overlap this namespace).
  """
  @spec branch_for_pod(String.t()) :: String.t()
  def branch_for_pod(pod_id) when is_binary(pod_id),
    do: @request_prefix <> "pod-" <> slug(pod_id)

  # Collapse byte-wise replacements of non-ASCII characters into readable separators.
  # Slugging is lossy: distinct input keys can produce the same branch suffix.
  defp slug(key) do
    key
    |> String.replace(~r/[^A-Za-z0-9._-]/, "-")
    |> String.replace(~r/-{2,}/, "-")
    |> String.trim("-")
  end

  @doc """
  Sysadmin repository: `:lcars_fleet, :pilot_ops_repo`, default `lcars/_ops`.
  Keep this key/default aligned with IncidentRegistry.Escalation so requests and incidents
  reach the same repo. The reader is repeated because MCP cannot depend on Pilot.
  """
  @spec ops_repo() :: String.t()
  def ops_repo, do: Application.get_env(:lcars_fleet, :pilot_ops_repo, "lcars/_ops")

  @doc """
  Protected manifest branch, fixed by design as `tool_request`.
  Provisioning, protection, convergence and the BEAM must agree; the contract checker
  `toolchain.branch_single_source` checks the shell copies against this name. Do not add a
  setting read by only part of that chain. This branch is separate from runtime-writable ops:
  protecting ops would break incident-registry writes.
  """
  @spec branch() :: String.t()
  def branch, do: "tool_request"

  @doc """
  One manifest path per ecosystem, so later requests amend the same declaration.
  The caller must validate the ecosystem before using it as this path component.
  """
  @spec manifest_path(String.t()) :: String.t()
  def manifest_path(ecosystem) when is_binary(ecosystem),
    do: "ops/toolchains.d/" <> ecosystem <> ".yaml"

  @doc """
  Parses an integer from `issue-<n>`, otherwise `:error`.
  Mirrors Fleet.Pilot.IssueId's format across a dependency boundary; keep the round-trip witness.
  """
  @spec workitem_issue_number(String.t() | nil) :: {:ok, integer()} | :error
  def workitem_issue_number("issue-" <> rest) do
    case Integer.parse(rest) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  def workitem_issue_number(_), do: :error

  @doc """
  Hidden issue-body marker linking a work item to its PR, preserved on the forge across restarts.
  """
  @spec marker(integer()) :: String.t()
  def marker(pr) when is_integer(pr), do: "<!-- lcars-toolchain:#{pr} -->"

  @doc """
  Hidden PR-body marker linking back to the waiting issue. The reconciler needs it for
  closure without merge, which does not move the protected branch head.
  """
  @spec workitem_marker(String.t(), integer()) :: String.t()
  def workitem_marker(repo, issue) when is_binary(repo) and is_integer(issue),
    do: "<!-- lcars-toolchain-workitem:#{repo}##{issue} -->"

  @doc """
  Reads a `workitem_marker/2` back from a PR body. `:error` when absent or malformed — a PR toward
  the protected branch that carries no marker is not OURS (posée à la main) : le drain la saute.
  """
  @spec parse_workitem_marker(String.t() | nil) :: {:ok, String.t(), integer()} | :error
  def parse_workitem_marker(body) when is_binary(body) do
    case Regex.run(~r/<!-- lcars-toolchain-workitem:([^#\s]+)#(\d+) -->/, body) do
      [_, repo, n] -> {:ok, repo, String.to_integer(n)}
      _ -> :error
    end
  end

  def parse_workitem_marker(_), do: :error

  @doc """
  Label for work awaiting a toolchain request, defined by `Fleet.Labels.awaits_toolchain/0`.
  """
  @spec waiting_label() :: String.t()
  def waiting_label, do: Labels.awaits_toolchain()

  defp form_block(req) do
    Enum.find_value(@forms, fn form ->
      case req[form] do
        m when is_map(m) -> form <> ":\n" <> map_block(m, "  ")
        _ -> nil
      end
    end)
  end

  defp hosts_block(nil), do: nil
  defp hosts_block([]), do: nil

  defp hosts_block(hosts) when is_list(hosts),
    do: "egress_hosts:\n" <> Enum.map_join(hosts, "\n", &("  - " <> yaml_scalar(&1)))

  defp requested_by_block(meta) do
    fields =
      [issue: meta[:issue], role: meta[:role], work_item: meta[:work_item_id]]
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)

    case fields do
      [] ->
        nil

      f ->
        "requested_by:\n" <> Enum.map_join(f, "\n", fn {k, v} -> "  #{k}: #{yaml_scalar(v)}" end)
    end
  end

  # A literal block preserves diagnostic quotes, colons and backslashes without scalar escaping.
  defp evidence_block(nil), do: nil
  defp evidence_block(""), do: nil

  defp evidence_block(text) when is_binary(text) do
    body =
      text
      |> String.split("\n")
      |> Enum.map_join("\n", &("  " <> &1))

    "# — POUR L'HUMAIN QUI SIGNE. Jamais lu par l'exécuteur.\nevidence: |-\n" <> body
  end

  defp map_block(map, indent) do
    map
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map_join("\n", fn
      {k, v} when is_list(v) ->
        "#{indent}#{k}:\n" <> Enum.map_join(v, "\n", &("#{indent}  - " <> yaml_scalar(&1)))

      {k, v} ->
        "#{indent}#{k}: #{yaml_scalar(v)}"
    end)
  end

  # Quote numeric-looking strings such as versions. This is not a general YAML escaper;
  # some MCP fields (version, sources, paths) accept strings without character restrictions.
  defp yaml_scalar(v) when is_integer(v), do: Integer.to_string(v)

  defp yaml_scalar(v) when is_binary(v) do
    if Regex.match?(~r/\A[A-Za-z][A-Za-z0-9._\/-]*\z/, v), do: v, else: "\"" <> v <> "\""
  end

  defp yaml_scalar(v), do: "\"" <> to_string(v) <> "\""
end
