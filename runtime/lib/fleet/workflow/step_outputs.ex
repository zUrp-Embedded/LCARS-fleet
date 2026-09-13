defmodule Fleet.Workflow.StepOutputs do
  @moduledoc """
  Derives output-existence and size facts from a step's declared paths in the
  supplied workspace. Callers merge these facts over pod-reported results.

  Each {...} segment becomes * before Path.wildcard: dates have no prescribed
  format, and existing glob syntax also applies. Every declared pattern must
  match a regular file for outputs_exist; every pattern must have at least one
  nonempty match for outputs_non_empty. Files can predate this step; these facts
  establish neither authorship nor content quality.

  Absolute paths and .. components are refused before filesystem reads. This is
  lexical validation, not symlink containment: regular-file/stat checks follow
  links, and concurrent changes can affect the observations.

  Missing, nil or empty outputs produce no facts (%{}). Malformed declarations,
  missing workspace strings and rescued exceptions log a reason and set both
  facts false. Missing files also yield false but do not log a shape error.
  """

  require Logger

  @doc """
  Names of system-derived facts. This function does not modify pod results;
  GateEngine overrides these keys only when derive/2 returns nonempty facts.
  """
  @spec system_keys() :: [String.t()]
  def system_keys, do: ["outputs_exist", "outputs_non_empty"]

  @doc """
  Derives `%{"outputs_exist" => bool, "outputs_non_empty" => bool}` from `spec["outputs"]`,
  resolved under `workspace`.

  Requires a map spec. Returns %{} for no declaration; exceptions within the
  map clause are rescued into two false facts. Non-map calls do not match a clause.
  """
  @spec derive(map(), String.t() | nil) :: %{optional(String.t()) => boolean()}
  def derive(spec, workspace) when is_map(spec) do
    case Map.get(spec, "outputs") do
      nil -> %{}
      [] -> %{}
      declared -> derive_declared(declared, workspace)
    end
  rescue
    # A failed derivation must not look like an absent declaration.
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

  # Refuse path shape separately from missing files, even if .. would stay inside the root.
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
