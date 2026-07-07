defmodule Fleet.Workflow.GitRef do
  @moduledoc """
  Single source for validating a git branch / ref name on the system side.

  Guardrail against catalogue/brief inputs that are manifestly broken (space, `..`, leading `-`):
  NOT an anti-injection defense (`System.cmd` uses no shell), but a boundary that keeps a malformed
  name from reaching a raw `git push`/`commit`. Roughly aligned with `git check-ref-format`:
  starts with an alphanumeric, then `[A-Za-z0-9._/-]`, and rejects the `..` substring.

  Consumed by `Fleet.Workflow.Git` (`check_branch`) and `Fleet.Workflow.Deliverable` (`check_ref`) —
  which each carried a copy of the same regex. Each caller keeps ITS typed error shape
  (`:invalid_branch` / `{:invalid_ref, ref}`); only the `valid?` decision is centralized here.
  """

  @ref_re ~r/^[A-Za-z0-9][A-Za-z0-9._\/\-]*$/

  @doc """
  `true` if `ref` is a well-formed branch/ref name: binary, matches `@ref_re` (alphanumeric head +
  `[A-Za-z0-9._/-]`) AND does NOT contain `..`. Everything else (non-binary, empty, leading `-`, space) → `false`.
  """
  @spec valid?(term()) :: boolean()
  def valid?(ref) when is_binary(ref),
    do: Regex.match?(@ref_re, ref) and not String.contains?(ref, "..")

  def valid?(_), do: false
end
