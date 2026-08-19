defmodule Fleet.Toolchain do
  use Boundary, deps: [Fleet.Labels], exports: []

  @moduledoc """
  A blocked pod asks for a tool the box does not have — and the ask becomes a DIFF a human signs.

  ## Why the pod never writes the declaration

  The pod hands TYPED FIELDS through its MCP tool; this module renders them. That split is the
  whole guard: the tool's `input_schema` bounds what can be expressed AT THE WIRE, so a request
  outside the shape is refused before it is a request — not validated afterwards by a checker
  someone can forget to call. What the human approves is therefore a document the runtime
  composed, never prose the pod authored.

  Two fields are the exception and they are load-bearing in opposite directions: `evidence` is
  free text read BY THE HUMAN and by nothing else, and `ecosystem` is the key the box converges on.
  Everything between them is a closed enum, a pattern, or a list of patterns.

  ## What it produces

  A YAML manifest on a request branch, and a pull request onto the protected branch. Nothing is
  installed by this module and nothing is installed by the merge either: the reconciler notices the
  branch moved and the converger applies it. Three actors, and the only one that runs as root takes
  a manifest that a human already approved.

  ## Why this sits at the FOUNDATION and not under `Fleet.Pilot`

  Two domains read it and neither may depend on the other: `Fleet.MCP` renders the request the pod
  typed, and the reconciler applies what a human merged. MCP sits BELOW the pilot by construction,
  so a shared piece placed in either would force one of them upward. It carries no state, no forge
  call and no side effect — only the vocabulary of a request and how it is written down.

  ## The form is exclusive, and that is not tidiness

  `apt`, `installer` and `sysroot` do different things to different places — the box's `/usr`, an
  SDK tree under the store, a target sysroot. A request carrying two of them would make the human
  approve one diff for two effects, and the executor pick an order nobody declared.
  """

  require Logger

  alias Fleet.Labels

  @forms ~w(apt installer sysroot)

  @typedoc "The typed request, as the MCP tool's `input_schema` bounds it."
  @type request :: map()

  @doc """
  Renders the request as the YAML the human will read in the diff.

  DETERMINISTIC AND ORDERED, because it lands in a git diff: a map iterated in whatever order the
  runtime felt like would show a reordering as a change, and a reviewer who learns that diffs lie
  stops reading them. Keys go out in a fixed sequence, and lists keep the order they arrived in.

  `evidence` is rendered LAST and as a block scalar. It is the only free text in the document, so
  it sits where it cannot be mistaken for a field the executor reads — and a reviewer scrolling to
  the end finds the reason for the whole request instead of hunting for it.
  """
  @spec render(request(), keyword()) :: String.t()
  def render(req, meta \\ []) when is_map(req) do
    [
      "# Généré par le rail toolchain — NE PAS ÉDITER À LA MAIN.",
      "# Ce que tu approuves en mergeant : le convergeur appliquera EXACTEMENT ce document,",
      "# au SHA de ce merge, sur toutes les boîtes qui suivent cette branche.",
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
  Refuses a request that does not carry EXACTLY ONE of `apt`, `installer`, `sysroot`.

  The wire schema cannot say "exactly one" on its own, so it is said here — and it is said as a
  REFUSAL rather than a repair: picking one for the pod would approve, in the human's name, a form
  they never chose.
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

  @doc """
  The request branch name for a work item — stable, so a retry lands on the SAME branch instead of
  opening a second pull request for one need.
  """
  @spec branch_for(String.t()) :: String.t()
  def branch_for(work_item_id) when is_binary(work_item_id) do
    # LES SÉRIES DE TIRETS SONT REPLIÉES, et ce n'est pas cosmétique : la substitution travaille sur
    # les OCTETS, donc un caractère non-ASCII en rend deux ou trois. Sans le repli, le nom de branche
    # dépendrait de l'encodage du work-item id — lisible pour un ascii, illisible pour le reste, et
    #variable selon la largeur du caractère. Replié, il ne dépend que du contenu.
    slug =
      work_item_id
      |> String.replace(~r/[^A-Za-z0-9._-]/, "-")
      |> String.replace(~r/-{2,}/, "-")
      |> String.trim("-")

    "lcars/toolchain-" <> slug
  end

  @doc """
  The repository the sysadmin domain lands on — `:lcars_fleet, :pilot_ops_repo`, default
  `"fleet/lcars"`.

  ⚠ LA MÊME CLEF QUE `IncidentRegistry.Escalation.ops_repo/0`, ET C'EST VOULU : les issues
  `error_system` et le manifeste d'outillage sont deux faces d'un même domaine, et son propre
  moduledoc porte l'argument — *« a registry on repo A whose issues open on repo B is an alarm
  nobody finds »*. Le lecteur est dupliqué parce que `Fleet.MCP` ne peut pas dépendre de
  `Fleet.Pilot`, qui est au-dessus ; la CLEF et le DÉFAUT, eux, ne le sont pas. Les faire diverger
  enverrait la demande sur un dépôt et son escalade sur un autre.
  """
  @spec ops_repo() :: String.t()
  def ops_repo, do: Application.get_env(:lcars_fleet, :pilot_ops_repo, "fleet/lcars")

  @doc """
  The protected branch the manifest lives on — `:lcars_fleet, :toolchain_branch`, default
  `"sysadmin"`.

  PAS `ops`, et la raison est mesurée : le runtime ÉCRIT déjà sur `ops` (le registre d'incidents),
  donc la protéger casserait ces écritures. Même dépôt, branche différente, protections opposées.
  """
  @spec branch() :: String.t()
  def branch, do: Application.get_env(:lcars_fleet, :toolchain_branch, "sysadmin")

  @doc """
  The manifest path a request writes to, keyed on the ecosystem.

  ONE FILE PER ECOSYSTEM, not one per request: two pods asking for python must converge on the same
  document rather than accumulate one file each. The second request edits what the first declared,
  and the diff shows a human what actually changes.
  """
  @spec manifest_path(String.t()) :: String.t()
  def manifest_path(ecosystem) when is_binary(ecosystem),
    do: "ops/toolchains.d/" <> ecosystem <> ".yaml"

  @doc """
  Le numéro d'issue d'un `WorkItem.issue_id` (`"issue-<n>"`), ou `:error`.

  ⚠ MIROIR, pas autorité : le format est composé par `Fleet.Pilot.IssueId.compose/1`, mais la
  frontière interdit `Fleet.MCP -> Fleet.Pilot` — même motif que le miroir de slug du SeedStore
  (`lcars.slug_witness` le confronte au réel). Deux lignes, un préfixe : si le format bouge,
  le témoin du round-trip casse ici.
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
  The hidden marker that ties a work item to its pull request.

  On the ISSUE, in an HTML comment — invisible rendered, exact in the body text. Same shape and
  same reason as `IncidentRegistry.Escalation`'s incident marker: the forge carries the key, never
  a volatile map in the runtime, so a restart does not lose which ticket waits on which PR.
  """
  @spec marker(integer()) :: String.t()
  def marker(pr) when is_integer(pr), do: "<!-- lcars-toolchain:#{pr} -->"

  @doc """
  The hidden marker that ties a pull request BACK to its work item — the inverse of `marker/1`.

  On the PR BODY. The reconciler's second pass reads it to find WHICH ticket to drain when the PR
  closes (merged or refused) : la branche ne bouge pas sur une fermeture sans merge, donc la
  comparaison de head ne verra JAMAIS ce cas — seul ce marqueur relie la PR au ticket qui attend.
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
  The label a work item wears while its request is in flight — `Fleet.Labels.awaits_toolchain/0`.

  Restated here as a function rather than inlined at call sites so the vocabulary keeps ONE
  source; `Fleet.Labels` explains why it is not `awaits_arch`.
  """
  @spec waiting_label() :: String.t()
  def waiting_label, do: Labels.awaits_toolchain()

  # ── rendering ───────────────────────────────────────────────────────────────────────────────

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
      [] -> nil
      f -> "requested_by:\n" <> Enum.map_join(f, "\n", fn {k, v} -> "  #{k}: #{yaml_scalar(v)}" end)
    end
  end

  # A BLOCK SCALAR, and `|-` rather than a quoted string: an error message carries quotes, colons
  # and backslashes, and re-escaping it would let a wrong escape turn a diagnosis into a parse
  # error. `|-` takes the lines as they are; the indentation is the only syntax.
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

  # QUOTED WHEN IT COULD BE READ AS SOMETHING ELSE. A version like `1.27` is a float to YAML and a
  # string to everyone else; `deb http://…` carries a colon-space that opens a mapping. The values
  # here come through patterns that forbid quotes and newlines (the tool's schema), so quoting is
  # enough and escaping would be theatre.
  defp yaml_scalar(v) when is_integer(v), do: Integer.to_string(v)

  defp yaml_scalar(v) when is_binary(v) do
    if Regex.match?(~r/\A[A-Za-z][A-Za-z0-9._\/-]*\z/, v), do: v, else: "\"" <> v <> "\""
  end

  defp yaml_scalar(v), do: "\"" <> to_string(v) <> "\""
end
