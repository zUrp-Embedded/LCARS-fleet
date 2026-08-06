defmodule Fleet.GitRef do
  use Boundary, deps: [], exports: []

  @moduledoc """
  Single source for validating a git branch / ref name, system-wide.

  Guardrail against catalogue/brief inputs that are manifestly broken (space, `..`, leading `-`):
  NOT an anti-injection defense (`System.cmd` uses no shell), but a boundary that keeps a malformed
  name from reaching a raw `git clone`/`push`/`commit`. Enforces the `git check-ref-format` rules
  that a charset regex alone misses — the full git authority, not "roughly aligned".

  PURE foundation primitive (alongside `Fleet.Slug`) so BOTH the workflow (`Git`/`Deliverable`)
  and the project bootstrap (`Phase.Clone`) validate refs at their OWN boundary without an upward
  compile edge. Each caller keeps ITS typed error shape (`:invalid_branch` / `{:invalid_ref, ref}`);
  only the `valid?` decision is centralized.

  **Last revised**: 2026-07-18
  """

  # `\A…\z`, NOT `^…$`: in PCRE `$` also matches just BEFORE a trailing newline, so `^…$` declares
  # "main\n" VALID and the ref reaches git clone/push/commit — the exact class this module exists to
  # stop. Same trap, same fix as `Fleet.Slug` and `Fleet.Spawner.valid_pod_id?`.
  @ref_re ~r/\A[A-Za-z0-9][A-Za-z0-9._\/\-]*\z/

  @doc """
  `true` if `ref` is a well-formed **ref** name (git's ref grammar). Binary, matches `@ref_re`
  (alphanumeric head + `[A-Za-z0-9._/-]`, which already excludes space/`~^:?*[\\`/`@{`), AND none of
  the rules a charset regex misses: no `..`; no trailing `.`; and every `/`-separated component is
  non-empty (→ no `//`, no leading/trailing `/`), does not begin with `.`, and does not end with
  `.lock`. Everything else (non-binary, empty, leading `-`, space) → `false`.

  ## Ref, not branch-name — `"HEAD"` is deliberately VALID

  `git check-ref-format --branch` refuses `HEAD` (you cannot CREATE a branch named `HEAD`) —
  but this module gates the refs the runtime HANDS to git, and `"HEAD"` is the LOCAL side of
  every deliverable push (`git push <remote> HEAD:refs/heads/<branch>`: `Deliverable.local_ref/1`
  defaults to it, `StepRunBuild` sets it). The oracle for this contract is git's ref grammar,
  not `--branch` — a `--branch`-style check here would break the publication rail.
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
