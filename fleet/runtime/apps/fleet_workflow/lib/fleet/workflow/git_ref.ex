defmodule Fleet.Workflow.GitRef do
  @moduledoc """
  Single source for validating a git branch / ref name on the system side.

  Guardrail against catalogue/brief inputs that are manifestly broken (space, `..`, leading `-`):
  NOT an anti-injection defense (`System.cmd` uses no shell), but a boundary that keeps a malformed
  name from reaching a raw `git push`/`commit`. Enforces the `git check-ref-format` rules that a
  charset regex alone misses (R2-06 — full git authority, not "roughly aligned").

  Consumed by `Fleet.Workflow.Git` (`check_branch`) and `Fleet.Workflow.Deliverable` (`check_ref`) —
  which each carried a copy of the same regex. Each caller keeps ITS typed error shape
  (`:invalid_branch` / `{:invalid_ref, ref}`); only the `valid?` decision is centralized here.
  """

  @ref_re ~r/^[A-Za-z0-9][A-Za-z0-9._\/\-]*$/

  @doc """
  `true` if `ref` is a well-formed branch/ref name per `git check-ref-format`. Binary, matches
  `@ref_re` (alphanumeric head + `[A-Za-z0-9._/-]`, which already excludes space/`~^:?*[\\`/`@{`), AND
  none of the rules a charset regex misses: no `..`; no trailing `.`; and every `/`-separated component
  is non-empty (→ no `//`, no leading/trailing `/`), does not begin with `.`, and does not end with
  `.lock`. Everything else (non-binary, empty, leading `-`, space) → `false`.
  """
  @spec valid?(term()) :: boolean()
  def valid?(ref) when is_binary(ref) do
    Regex.match?(@ref_re, ref) and
      not String.contains?(ref, "..") and
      not String.ends_with?(ref, ".") and
      valid_components?(ref)
  end

  def valid?(_), do: false

  # git check-ref-format: no slash-separated component may be EMPTY (rejects `//`, leading/trailing `/`),
  # begin with `.` (a hidden component), or end with `.lock` (git's own ref-lock suffix).
  defp valid_components?(ref) do
    ref
    |> String.split("/")
    |> Enum.all?(fn comp ->
      comp != "" and
        not String.starts_with?(comp, ".") and
        not String.ends_with?(comp, ".lock")
    end)
  end
end
