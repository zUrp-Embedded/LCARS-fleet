defmodule Fleet.Workflow.StepOutputs do
  @moduledoc """
  Derives the SYSTEM's own facts about a step's declared `outputs`, checked in the pod workspace.

  ## Why this module exists (BL-6-59)

  The only hard gate rule of the canon corpus was `audit_doc_exists AND audit_doc_non_empty`, and
  both facts came from the pod's own `result`: **the producer attested that its own document existed
  and was not empty.** Meanwhile the card DECLARED the expected path three lines above the rule
  (`outputs: - audits/scribe-{date}.json`) and `outputs` had ZERO readers — the system knew what had
  to exist, in a field it never read, and asked the agent whether it existed.

  What this closes is that split: the declaration and the verification now meet. `outputs_exist` and
  `outputs_non_empty` are produced HERE, from the card's own declaration, against a workspace path
  the runtime created itself (`Fleet.Layout.pod_workspace_path/1`) — it never has to believe the pod
  to obtain it.

  ## The convention that had to be decided, and why it is a GLOB

  Closing this needs a resolution CONVENTION for the `{date}` family, not a repair — and the naming
  is the trap: a derivation that resolves `{date}` to a formatted date and demands an EXACT match
  answers `false` for a pod that spelled it otherwise, which BLOCKS every audit. Worse than the
  self-declaration it replaces.

  So a declared path is read as a **pattern**: every `{...}` segment becomes `*`, and the result is
  globbed under the workspace. This is deliberately the LOOSE direction. It never invents a date
  format nobody wrote, it never blocks a legitimate delivery, and it still answers the question the
  gate actually asks — *did the step produce something where it said it would?* Resolving `{date}`
  for real would require the cards to declare a format, which is a card-schema decision, not this
  one.

  ## What is NOT decided here

  Whether the CONTENT is any good. `outputs_non_empty` is a size check, nothing more — the semantic
  verdict belongs to a judge. The point of these two facts is that the mechanical half stops being
  self-reported, not that the gate becomes smart.

  ## Fail-closed, and the shape/verdict split

  A workspace we cannot resolve, a malformed `outputs`, or a path that escapes the workspace yields
  `false` for both facts and says WHICH of the three happened — the same rule `Fleet.Workflow.Gates`
  applies to malformed gates: a rule the engine cannot read is not a verdict about the work, and the
  message must let the reader tell "the card is wrong" from "the delivery failed".

  A step that declares NO `outputs` yields `%{}` — the absence of a fact, not `false`. The system
  says nothing about what the card did not declare; a rule that references these keys anyway falls
  onto `Predicate`'s own missing-evidence rule, which is the correct refusal for a card asking about
  a declaration it never made.
  """

  require Logger

  @doc """
  The keys this module owns. A pod `result` carrying one of them is OVERRIDDEN, never trusted:
  these are the facts whose self-declaration BL-6-59 exists to remove.
  """
  @spec system_keys() :: [String.t()]
  def system_keys, do: ["outputs_exist", "outputs_non_empty"]

  @doc """
  Derives `%{"outputs_exist" => bool, "outputs_non_empty" => bool}` from `spec["outputs"]`,
  resolved under `workspace`.

  Returns `%{}` when the step declares no outputs (nothing to say). Never raises.
  """
  @spec derive(map(), String.t() | nil) :: %{optional(String.t()) => boolean()}
  def derive(spec, workspace) when is_map(spec) do
    case Map.get(spec, "outputs") do
      nil -> %{}
      [] -> %{}
      declared -> derive_declared(declared, workspace)
    end
  rescue
    # A courtesy derivation can never break the gate it feeds — but it must not PASS either, so the
    # rescue is fail-closed and named, not a silent `%{}` (which would read as "not declared").
    e ->
      Logger.warning("StepOutputs: derivation raised (#{Exception.message(e)}) — fail-closed")
      both(false)
  end

  defp derive_declared(declared, workspace) do
    cond do
      not (is_list(declared) and declared != [] and Enum.all?(declared, &is_binary/1)) ->
        loud("malformed `outputs` (expected a list of strings, got #{inspect(declared)})")

      not (is_binary(workspace) and workspace != "") ->
        loud("no workspace on the completion payload — cannot check declared outputs")

      Enum.any?(declared, &escapes?/1) ->
        loud(
          "a declared output escapes the workspace (absolute path or `..`): #{inspect(declared)}"
        )

      true ->
        matched = Enum.map(declared, &files_for(workspace, &1))

        %{
          "outputs_exist" => Enum.all?(matched, &(&1 != [])),
          "outputs_non_empty" =>
            Enum.all?(matched, fn files -> Enum.any?(files, &non_empty?/1) end)
        }
    end
  end

  # A declared output is workspace-relative BY CONSTRUCTION: the card describes what the step
  # produces in its own working copy. An absolute path or a `..` segment is a card that reaches
  # outside — refused on SHAPE, before any filesystem look, so the refusal cannot be mistaken for a
  # missing file.
  defp escapes?(path) do
    Path.type(path) != :relative or ".." in Path.split(path)
  end

  # `{...}` → `*` (see the moduledoc). `Path.wildcard/1` does the rest; a pattern matching nothing
  # yields `[]`, which is exactly `outputs_exist == false`.
  defp files_for(workspace, declared) do
    pattern = Regex.replace(~r/\{[^}]*\}/, declared, "*")

    workspace
    |> Path.join(pattern)
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
  end

  defp non_empty?(file) do
    case File.stat(file) do
      {:ok, %File.Stat{size: size}} -> size > 0
      _ -> false
    end
  end

  defp loud(reason) do
    Logger.warning("StepOutputs: #{reason} — outputs_exist/outputs_non_empty forced false")
    both(false)
  end

  defp both(value), do: %{"outputs_exist" => value, "outputs_non_empty" => value}
end
