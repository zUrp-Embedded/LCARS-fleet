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
