defmodule Fleet.GitRef do
  # Z4 migration (2026-07-12) — frontière COMPILÉE du domaine : deps = graphe ex-umbrella
  # régularisé (successeur mécanique du verrou topologie, D-19), exports = la SURFACE
  # cross-domaine MESURÉE (Z4c : tout à [] puis violations constatées → liste). Le
  # compilateur refuse toute violation — plus de discipline. Rétrécir = geste Z6+.
  use Boundary, deps: [], exports: []

  @moduledoc """
  Single source for validating a git branch / ref name, system-wide.

  Guardrail against catalogue/brief inputs that are manifestly broken (space, `..`, leading `-`):
  NOT an anti-injection defense (`System.cmd` uses no shell), but a boundary that keeps a malformed
  name from reaching a raw `git clone`/`push`/`commit`. Enforces the `git check-ref-format` rules that a
  charset regex alone misses (R2-06 — full git authority, not "roughly aligned").

  PURE primitive living in Ring 0 (alongside `Fleet.Slug`) so BOTH the workflow (`Git`/`Deliverable`,
  Ring 2) and the project bootstrap (`Phase.Clone`, Ring 1) validate refs at their OWN boundary without
  an upward compile edge — the reason it moved out of `fleet_workflow` (R1-07/08). Each caller keeps ITS
  typed error shape (`:invalid_branch` / `{:invalid_ref, ref}`); only the `valid?` decision is centralized.
  """

  # `\A…\z`, NOT `^…$`: in PCRE `$` also matches just BEFORE a trailing newline, so `^…$` declares
  # "main\n" VALID and the ref reaches git clone/push/commit — the exact class this module exists to
  # stop. Same trap, same fix as `Fleet.Slug` (its `valid_pod_id?` twin documents it too).
  @ref_re ~r/\A[A-Za-z0-9][A-Za-z0-9._\/\-]*\z/

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
