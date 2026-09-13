defmodule Fleet.MCP.PodTools.Delegation.ForgeWriter do
  @moduledoc """
  Content-writing forge callbacks used by runtime-composed toolchain requests.
  Separate from the issue/PR read surface so stubs declare only contracts they need.
  Gate.conforming checks every declared export; it does not validate the content
  or prove that a human approved a change. Callers compose typed MCP inputs into manifests.
  """

  @doc """
  Creates a request branch from an existing ref, keeping proposed manifests off the
  protected branch until merge. Downstream reconciliation consumes the merged declaration.
  """
  @callback create_branch(
              repo :: String.t(),
              branch :: String.t(),
              old_ref :: String.t(),
              opts :: keyword()
            ) :: {:ok, term()} | {:error, term()}

  @doc """
  Writes/replaces a file on a branch. Toolchain uses one path per ecosystem so
  successive requests modify the same declaration instead of accumulating files.
  """
  @callback put_file(
              repo :: String.t(),
              path :: String.t(),
              content :: String.t(),
              opts :: keyword()
            ) :: {:ok, term()} | {:error, term()}

  @doc """
  Schedules automatic merging of an existing PR, subject to forge policy.
  This callback does not create a PR or itself establish human approval.
  """
  @callback schedule_auto_merge(
              repo :: String.t(),
              index :: integer(),
              opts :: keyword()
            ) :: :ok | {:error, term()}

  @callback add_label(
              repo :: String.t(),
              issue :: integer(),
              label :: String.t(),
              opts :: keyword()
            ) :: {:ok, term()} | {:error, term()}

  @callback post_comment(
              repo :: String.t(),
              issue :: integer(),
              body :: String.t(),
              opts :: keyword()
            ) :: {:ok, term()} | {:error, term()}

  # open_pr returns a number, including lookup of an existing PR after HTTP 409.
  # Preserve that narrow return contract; a map-returning stub can hide a broken wire PR number.
  @callback open_pr(
              repo :: String.t(),
              head :: String.t(),
              base :: String.t(),
              title :: String.t(),
              opts :: keyword()
            ) :: {:ok, integer()} | {:error, term()}

  @doc """
  Uses ForgeClient.resolved so reads and writes share both :mcp_forge_client and
  its default. Separate keys/defaults could leave a partially stubbed test writing
  through the real client.
  """
  @spec resolved() :: module()
  def resolved, do: Fleet.MCP.PodTools.Delegation.ForgeClient.resolved()
end
