defmodule Fleet.Pilot.ForgeClient.UrlSafe do
  @moduledoc """
  SAFE encoding of forge URL segments — the forge client's
  path-traversal lock. PURE cluster (binary → binary), zero config, zero I/O —
  distinct from the HTTP engine (Transport keeps the plumbing: config/token, Req,
  pagination, system login).

  ## Why (security)

  `repo`/`path`/`ref`/`username`/`topic`/`org`/`label_name` come from the brief (issue/PR), the
  catalogue or the config and are interpolated into the Gitea URL. A hostile segment (`../`, space,
  `?x=1`, `#frag`) would traverse the API (`/repos/owner/../admin/...`) or INJECT a query/fragment
  that would change the request's meaning. We therefore ENCODE each segment as close as possible to the
  interpolation — NOT a slug (a `repo` = `owner/name` AND a file `path` legitimately contain `/`), but
  an encoding that renders `..`/`/`/space/`?`/`#` INERT.

  Two pitfalls handled:

    1. a `/` injected INSIDE a component (`name = "x/../admin"`) would fabricate a false separator →
       `encode_seg` percent-encodes the `/` (`%2F`), it can no longer separate.
    2. a component that IS the path separator `.`/`..` (`repo = "fleet/../admin"`, the `..` is a
       whole component after split): `URI.encode_www_form` does NOT touch the `.` (unreserved character),
       so a raw `..` would SURVIVE and the server would normalize the path (traversal). We therefore
       NEUTRALIZE every `.`/`..` component by percent-encoding its dots (`..` → `%2E%2E`) → an inert
       literal segment on the wire, never a path operator. (An empty component `//` has no dots and does
       not traverse → left as-is.) This is the real lock of the repo vector.

  `encode_seg/1` = an atomic component (username, org, topic, label, ref-in-path);
  `encode_repo/1`/`encode_path/1` = multi-component (`owner/name`, `dir/sub/file`), structural `/`
  preserved, each component passed through the same lock. For a QUERY (`?ref=…`),
  `URI.encode_www_form` directly (cf. `ForgeClient.get_file`).
  """

  @doc "Encodes an atomic URL component (renders `/`, `..`, space, `?`, `#` inert)."
  @spec encode_seg(String.t()) :: String.t()
  def encode_seg(seg) when is_binary(seg), do: encode_component(seg)

  @doc """
  Encodes an `owner/name` preserving the structural `/` but neutralizing any `/`/`..`/traversal
  component injected INSIDE a component (owner or name).
  """
  @spec encode_repo(String.t()) :: String.t()
  def encode_repo(repo) when is_binary(repo) do
    repo |> String.split("/") |> Enum.map_join("/", &encode_component/1)
  end

  @doc """
  Encodes a multi-segment file path (`dir/sub/file.md`): structural `/` preserved, each
  component neutralized → an injected `..`/`.` is inert, no traversal of the contents API.
  """
  @spec encode_path(String.t()) :: String.t()
  def encode_path(path) when is_binary(path) do
    path |> String.split("/") |> Enum.map_join("/", &encode_component/1)
  end

  # ONE safe path component. A TRAVERSAL component (`.`/`..`) is percent-encoded on its dots
  # (`..` → `%2E%2E`) → an inert literal segment that the server will NOT normalize as a path
  # operator (the `.` is unreserved: `URI.encode_www_form` would not touch it, hence this dedicated case — it's
  # THE lock of the `owner/../admin` vector). An empty component (`//`) does not traverse → left as-is.
  # Any other component goes through `URI.encode_www_form` (the internal `/` becomes `%2F`, space `%20`,
  # `?`/`#` encoded). The `+` (www-form space) is re-translated to `%20` (path-segment semantics, not form).
  defp encode_component(comp) when comp in [".", ".."] do
    String.replace(comp, ".", "%2E")
  end

  defp encode_component(comp) when is_binary(comp) do
    comp |> URI.encode_www_form() |> String.replace("+", "%20")
  end
end
