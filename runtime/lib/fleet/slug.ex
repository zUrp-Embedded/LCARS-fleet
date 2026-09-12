defmodule Fleet.Slug do
  use Boundary, deps: [], exports: []

  @moduledoc """
  Validates atomic path and URL names without transforming them.

  A slug matches `\A[a-z0-9][a-z0-9_-]*\z`. `under_root?/2` and
  `confined_join/2` add lexical path confinement. Multi-segment paths, Pilot
  pod IDs, and the vendor-compatible SeedStore slug are distinct domains.
  """

  @slug_rx ~r/\A[a-z0-9][a-z0-9_-]*\z/

  @type t :: String.t()

  @doc """
  Validates a slug or returns `{:error, {:invalid_slug, raw}}`.

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
  Returns a valid slug or raises `ArgumentError`.

  ## Examples

      iex> Fleet.Slug.cast!("ok-1")
      "ok-1"
  """
  @spec cast!(term()) :: t()
  def cast!(name) do
    case cast(name) do
      {:ok, slug} -> slug
      {:error, {:invalid_slug, raw}} -> raise ArgumentError, "invalid slug: #{inspect(raw)}"
    end
  end

  @doc """
  Returns whether `name` is a valid slug.

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
  Returns whether expanded `dest` equals expanded `root` or lies below it.

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

    prefix =
      if String.ends_with?(expanded_root, "/"), do: expanded_root, else: expanded_root <> "/"

    expanded_dest == expanded_root or String.starts_with?(expanded_dest, prefix)
  end

  @doc """
  Checks lexical confinement, then rejects symlinks observed in components below root.
  Root itself and its ancestors are not checked; callers must trust them. Missing components
  are allowed for later creation, and other lstat errors also continue the walk.

  Lexical checks alone miss links into host files from a pod-writable tree. This check is still
  separate from the guarded read/write: paths can change in between. Recheck after an untrusted
  read and discard a result if a link is found; even that cannot detect a swap restored before
  the second check. This helper does not provide atomic no-follow access.

  ## Examples

      iex> Fleet.Slug.link_free_under?("/srv/store/sub", "/srv/store")
      true

      iex> Fleet.Slug.link_free_under?("/srv/store-evil", "/srv/store")
      false
  """
  @spec link_free_under?(Path.t(), Path.t()) :: boolean()
  def link_free_under?(dest, root) when is_binary(dest) and is_binary(root) do
    expanded_root = Path.expand(root)
    expanded_dest = Path.expand(dest)

    if under_root?(expanded_dest, expanded_root) do
      expanded_dest
      |> Path.relative_to(expanded_root)
      |> Path.split()
      |> Enum.reject(&(&1 == "."))
      |> Enum.reduce_while(expanded_root, &descend_link_free/2)
      |> is_binary()
    else
      false
    end
  end

  # A path accumulator means descent continued; false records a detected symlink.
  defp descend_link_free(segment, acc) do
    path = Path.join(acc, segment)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> {:halt, false}
      _ -> {:cont, path}
    end
  end

  @doc """
  Validates `name`, joins it below `root`, and verifies lexical confinement.

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
