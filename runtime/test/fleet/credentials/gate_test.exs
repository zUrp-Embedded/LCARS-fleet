defmodule Fleet.Credentials.GateTest do
  @moduledoc """
  Checks local credential-file shape and token-free status using temporary claudeDir fixtures.
  No live vendor token, scope, plan or refresh validation is exercised.
  """
  use ExUnit.Case, async: true

  alias Fleet.Credentials.Gate

  defp write_creds!(dir, json) do
    File.write!(Path.join(dir, ".credentials.json"), json)
  end

  @tag :tmp_dir
  test "valid login (claudeAiOauth with a non-empty accessToken) → :ok", %{tmp_dir: dir} do
    write_creds!(dir, ~s({"claudeAiOauth":{"accessToken":"tok-abc","subscriptionType":"max"}}))
    assert :ok = Gate.validate(dir)
  end

  @tag :tmp_dir
  test "no scope/plan check anymore: a free plan with NO scopes still passes (login is enough)",
       %{
         tmp_dir: dir
       } do
    write_creds!(dir, ~s({"claudeAiOauth":{"accessToken":"tok-abc","subscriptionType":"free"}}))
    assert :ok = Gate.validate(dir)
  end

  @tag :tmp_dir
  test "no credentials file → {:credentials_invalid, {:credentials_unreadable, _, :enoent}}", %{
    tmp_dir: dir
  } do
    assert {:error, {:credentials_invalid, {:credentials_unreadable, _, :enoent}}} =
             Gate.validate(dir)
  end

  @tag :tmp_dir
  test "malformed JSON → categorized :malformed_json (never the raw content)", %{tmp_dir: dir} do
    write_creds!(dir, "{not json")

    assert {:error, {:credentials_invalid, {:credentials_unreadable, _, :malformed_json}}} =
             Gate.validate(dir)
  end

  @tag :tmp_dir
  test "decoded but no claudeAiOauth block → :no_oauth_block", %{tmp_dir: dir} do
    write_creds!(dir, ~s({"somethingElse":true}))

    assert {:error, {:credentials_invalid, {:credentials_unreadable, _, :no_oauth_block}}} =
             Gate.validate(dir)
  end

  @tag :tmp_dir
  test "oauth block present but empty/absent accessToken → :not_logged_in", %{tmp_dir: dir} do
    write_creds!(dir, ~s({"claudeAiOauth":{"accessToken":""}}))
    assert {:error, {:credentials_invalid, {:not_logged_in, _}}} = Gate.validate(dir)
  end

  describe "status/1 (BL-6-09 — the queryable, dashboard-safe login status)" do
    @tag :tmp_dir
    test "logged in → :logged_in with expires_at_ms as DATA, no token material", %{tmp_dir: dir} do
      write_creds!(
        dir,
        ~s({"claudeAiOauth":{"accessToken":"tok-abc","refreshToken":"ref-x","expiresAt":1754130000000}})
      )

      assert %{status: :logged_in, path: path, expires_at_ms: 1_754_130_000_000} =
               status = Gate.status(dir)

      assert path =~ ".credentials.json"

      # A closed key set also rejects added token fragments, which full-token substring checks miss.
      assert status |> Map.keys() |> Enum.sort() == [:expires_at_ms, :path, :status]
      refute inspect(status) =~ "tok-abc"
      refute inspect(status) =~ "ref-x"
    end

    @tag :tmp_dir
    test "expiresAt null is a legitimate durable login → expires_at_ms nil, still :logged_in",
         %{tmp_dir: dir} do
      write_creds!(dir, ~s({"claudeAiOauth":{"accessToken":"tok-abc","expiresAt":null}}))
      assert %{status: :logged_in, expires_at_ms: nil} = Gate.status(dir)
    end

    @tag :tmp_dir
    test "empty accessToken → :not_logged_in (no reason key — the category IS the fact)",
         %{tmp_dir: dir} do
      write_creds!(dir, ~s({"claudeAiOauth":{"accessToken":""}}))
      assert %{status: :not_logged_in, path: _} = Gate.status(dir)
    end

    @tag :tmp_dir
    test "absent file / foreign shape → :unreadable with the categorized reason", %{tmp_dir: dir} do
      assert %{status: :unreadable, reason: :enoent} = Gate.status(dir)

      write_creds!(dir, ~s({"somethingElse":true}))
      assert %{status: :unreadable, reason: :no_oauth_block} = Gate.status(dir)
    end
  end
end
