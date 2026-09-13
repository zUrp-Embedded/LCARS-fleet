# The API control listener starts only when api_control_socket is configured;
# test configuration leaves it absent. There is no TCP-listener flag to reset.

# Best-effort group-write repair for shared tmp leftovers from interrupted runs.
# chmod can fail on another user's files; this is not a cleanup guarantee.
_ =
  case File.stat("tmp") do
    {:ok, _} -> System.cmd("chmod", ["-R", "g+rwX", "tmp"], stderr_to_stdout: true)
    _ -> :ok
  end

# Resolve machine prerequisites at suite startup into ExUnit exclusions, so missing
# binaries/artifacts are reported as excluded rather than passing unexercised tests.
missing_prerequisites =
  for {quoi, tag, present?} <- [
        {"curl", :requires_curl, fn -> System.find_executable("curl") != nil end},
        {"git", :requires_git, fn -> System.find_executable("git") != nil end},
        {"assets/ (la marque du depot)", :requires_brand,
         fn -> File.dir?(Path.expand("../../assets/avatars", __DIR__)) end},
        {"bin/lcars-toolchain-converge", :requires_toolchain_script,
         fn -> File.exists?(Path.expand("../bin/lcars-toolchain-converge", __DIR__)) end}
      ],
      not present?.(),
      do: {quoi, tag}

for {quoi, tag} <- missing_prerequisites do
  IO.puts(
    "test_helper: #{quoi} missing on this machine — #{inspect(tag)} tests are EXCLUDED (visible in the bilan)"
  )
end

# RoleToken uses a socket; the shared authority double serves existing file fixtures.
# It resolves credentials_role_tokens_dir per request, so tests changing that global
# configuration must serialize and restore it.
_ = Fleet.Test.AuthorityDouble.start()

ExUnit.start(exclude: Enum.map(missing_prerequisites, fn {_binary, tag} -> tag end))
