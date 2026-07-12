defmodule Fleet.Slug do
  # Z4 migration (2026-07-12) — frontière COMPILÉE du domaine : deps = graphe ex-umbrella
  # régularisé (successeur mécanique du verrou topologie, D-19), exports = la SURFACE
  # cross-domaine MESURÉE (Z4c : tout à [] puis violations constatées → liste). Le
  # compilateur refuse toute violation — plus de discipline. Rétrécir = geste Z6+.
  use Boundary, deps: [], exports: []

  @moduledoc """
  Smart-constructor for a CONFINED-BY-CONSTRUCTION name used as an FS path
  component or a bounded URL segment.

  ## The problem it closes

  A name supplied by a client / a payload / a catalogue (a checkpoint name
  `rc_name`, a modop name, a workflow_map name, a forge repo/branch name…)
  often ends up interpolated into a `Path.join` (FS leaf) or a URL segment.
  If it carries `..`, `/`, a NUL byte or a control character, it TRAVERSES
  outside the expected root or breaks/injects the URL. Checking after the
  fact is fragile; instead we make the forbidden state UNREPRESENTABLE: we
  cast the name AS EARLY AS POSSIBLE, fail-closed, and a malformed name
  NEVER reaches a `Path.join`.

  ## The slug contract

  A valid slug matches `^[a-z0-9][a-z0-9_-]*$`:

    * lowercase / digits / `_` / `-` only;
    * starts with `[a-z0-9]` (so NO leading `-`/`_` — no slug that looks
      like a `-rf` flag, no "hidden" name);
    * non-empty;
    * no `/` (a single path component), no `.` (so neither `.` nor `..` —
      no directory traversal), no NUL byte nor control character (excluded
      by the charset), no misleading unicode (homoglyphs outside
      `[a-z0-9_-]` are rejected).

  This is the SAME charset as the path-safe regexes historically copied
  around (role, role_token…) — now centralized here, a single source.

  ## Confinement to the FS leaf

  Casting the segment is not enough if the ROOT itself is computed: we add
  `under_root?/2` (the resolved path stays `== root` or under `root <>
  "/"`) and `confined_join/2` (cast + join + confine in one shot).
  `Path.expand` is LEXICAL (it resolves `..`, not symlinks) — the slug has
  already killed the `..`, the confinement is the belt on top of the
  suspenders.

  ## When NOT to use the slug (multi-segment URL case)

  A legitimate forge `path` may contain `/` (`docs/sub/file.md`): that is
  not a slug, it must be ENCODED (`URI.encode`/`URI.encode_www_form`)
  segment by segment, not refused. The slug is for names that MUST be
  atomic (repo, bounded branch, modop/workflow_map/checkpoint name).

  ## Do NOT confuse with two other "slugs" (distinct domains, do not merge)

  Two functions look like a slug but are NOT, and must NOT be folded in here:

    * `Fleet.Pilot.PodId.component/1` — TRANSFORMS into the pod_id charset
      `[A-Za-z0-9._-]` (case and `.` preserved, contract `valid_pod_id?`);
      `Fleet.Slug` VALIDATES/rejects, strict lowercase, no `.`.
    * `Fleet.Spawner.SeedStore.slugify/1` — reproduces Claude Code's algo
      BIT FOR BIT (vendor compat); replacing it with `Fleet.Slug` would
      break resume. See the comment over there.
  """

  # Canonical path-safe charset: lowercase/digit/`_`/`-`, first position never `-`/`_`.
  # `\A..\z` (not `^..$`) → STRICT whole-string anchoring: `^`/`$` also match a line
  # boundary, so a multi-line name `"ok\n../evil"` would pass `^[a-z0-9...]$`.
  @slug_rx ~r/\A[a-z0-9][a-z0-9_-]*\z/

  @type t :: String.t()

  @doc """
  Casts a name into a confined slug. `{:ok, slug}` if the name matches the
  contract, otherwise `{:error, {:invalid_slug, raw}}` (fail-closed — a
  malformed name never comes back out as a usable slug).

  ## Examples

      iex> Fleet.Slug.cast("my-checkpoint-1")
      {:ok, "my-checkpoint-1"}

      iex> Fleet.Slug.cast("../evil")
      {:error, {:invalid_slug, "../evil"}}
  """
  @spec cast(term()) :: {:ok, t()} | {:error, {:invalid_slug, term()}}
  def cast(name) when is_binary(name) do
    if Regex.match?(@slug_rx, name), do: {:ok, name}, else: {:error, {:invalid_slug, name}}
  end

  def cast(name), do: {:error, {:invalid_slug, name}}

  @doc """
  Fail-loud variant of `cast/1` for sites where an invalid slug is a
  programming bug (never a client input): raises `ArgumentError`.

  ## Examples

      iex> Fleet.Slug.cast!("ok-1")
      "ok-1"
  """
  @spec cast!(term()) :: t()
  def cast!(name) do
    case cast(name) do
      {:ok, slug} -> slug
      {:error, {:invalid_slug, raw}} -> raise ArgumentError, "slug invalide: #{inspect(raw)}"
    end
  end

  @doc """
  Predicate: is `name` a valid slug?

  ## Examples

      iex> Fleet.Slug.valid?("engineer")
      true

      iex> Fleet.Slug.valid?("../x")
      false
  """
  @spec valid?(term()) :: boolean()
  def valid?(name) when is_binary(name), do: Regex.match?(@slug_rx, name)
  def valid?(_), do: false

  @doc """
  Confinement guard: does the resolved `dest` path stay UNDER `root`
  (`== root` or starting with `root <> "/"`)? `Path.expand` resolves `..`
  lexically → a `dest` that climbs above the root is rejected. Both sides
  are expanded (a relative `root` does not skew the comparison).

  ## Examples

      iex> Fleet.Slug.under_root?("/srv/store/sub", "/srv/store")
      true

      iex> Fleet.Slug.under_root?("/srv/store-evil", "/srv/store")
      false
  """
  @spec under_root?(Path.t(), Path.t()) :: boolean()
  def under_root?(dest, root) when is_binary(dest) and is_binary(root) do
    expanded_root = Path.expand(root)
    expanded_dest = Path.expand(dest)

    # The separator is appended ONLY when the root does not already end with one — i.e. only when
    # the root is not `/` itself. Concatenating unconditionally turned the root `/` into the prefix
    # `//`, which no expanded path starts with: `under_root?("/x", "/")` came out FALSE and
    # `confined_join("/", name)` was structurally impossible, though the contract promises "== root
    # or under root". Fail-CLOSED (a false reject, never an escape) — but a guard that refuses the
    # legal case is a guard nobody can use. Found by the confinement property.
    prefix = if String.ends_with?(expanded_root, "/"), do: expanded_root, else: expanded_root <> "/"

    expanded_dest == expanded_root or String.starts_with?(expanded_dest, prefix)
  end

  @doc """
  Casts `name` into a slug UNDER `root` and VERIFIES the confinement. This is
  the complete gesture expected at an FS leaf whose component comes from an
  input: `{:ok, abs}` (valid slug AND path confined under the root), otherwise
  `{:error, {:invalid_slug, name}}` (malformed name) or
  `{:error, {:path_escape, abs}}` (confinement fails — belt-and-suspenders
  guard: with a slug the `..` is already impossible, but if the root itself
  is suspect we refuse rather than write out-of-zone).

  ## Examples

      iex> Fleet.Slug.confined_join("/srv/store", "proj-1")
      {:ok, "/srv/store/proj-1"}

      iex> Fleet.Slug.confined_join("/srv/store", "../evil")
      {:error, {:invalid_slug, "../evil"}}
  """
  @spec confined_join(Path.t(), term()) ::
          {:ok, Path.t()} | {:error, {:invalid_slug, term()} | {:path_escape, Path.t()}}
  def confined_join(root, name) when is_binary(root) do
    with {:ok, slug} <- cast(name) do
      abs = Path.expand(Path.join(root, slug))
      if under_root?(abs, root), do: {:ok, abs}, else: {:error, {:path_escape, abs}}
    end
  end
end
