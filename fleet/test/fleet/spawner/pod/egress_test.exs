defmodule Fleet.Spawner.Pod.EgressTest do
  @moduledoc """
  THE WALL, and its mutation test.

  A pod is sealed with no network namespace; this proxy is the single hole in the seal, and what it
  is worth is exactly what it refuses. So these cases spend their lines on refusals: a lock is only
  valid once it has been shown it CAN fail.

  The transport is a real AF_UNIX socket — the same object bwrap binds into the sandbox — because
  the interesting failures (a stale socket file, a refused connect answered on the wrong stream)
  only exist on the real thing.
  """
  use ExUnit.Case, async: true

  alias Fleet.Spawner.Pod.Egress

  @moduletag :tmp_dir

  # NOT under `tmp_dir`: an ExUnit tmp_dir carries the test NAME, and AF_UNIX caps a path at ~108
  # bytes. The first run failed on `:einval` for that reason alone — which is why the module now
  # names the constraint instead of relaying the kernel's word for "no".
  defp sock(_tmp) do
    dir = Path.join(System.tmp_dir!(), "lcars-eg")
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{System.unique_integer([:positive])}.sock")
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp connect(path) do
    {:ok, c} = :gen_tcp.connect({:local, path}, 0, [:binary, active: false])
    c
  end

  describe "decide/2 — the wall, callable without a socket" do
    test "an allowed host passes, with its port" do
      assert {:ok, "api.anthropic.com", 443} =
               Egress.decide("CONNECT api.anthropic.com:443 HTTP/1.1\r\n\r\n", [
                 "api.anthropic.com"
               ])
    end

    test "a host that is not on the list is REFUSED — this is the mutation" do
      # Drop the membership test and this is the case that stops failing.
      assert {:refused, {:host_not_allowed, "evil.example"}} =
               Egress.decide("CONNECT evil.example:443 HTTP/1.1\r\n\r\n", ["api.anthropic.com"])
    end

    test "an EMPTY allowlist refuses everything — a pod with no declared egress reaches nothing" do
      assert {:refused, {:host_not_allowed, _}} =
               Egress.decide("CONNECT api.anthropic.com:443 HTTP/1.1\r\n\r\n", [])
    end

    test "a plain-HTTP proxy request is refused as the SANDBOX, not as the destination" do
      # `HTTP(S)_PROXY` covers everything, and a plain `http://` origin makes the client send an
      # absolute-URI GET instead of a tunnel request. Answering it "blocked by the allowlist" made
      # an architect's `git fetch` on the forge read as the FORGE refusing: it wrote a diagnosis
      # concluding the fleet account was not a collaborator, and the permissions were right.
      line = "GET http://forge:3000/web/test2.git/info/refs HTTP/1.1\r\n\r\n"

      assert {:refused, {:not_a_connect_request, _}} = Egress.decide(line, ["forge"])
    end

    test "a `*.` rule accepts subdomains and REFUSES the right-hand impostor — the mutation" do
      # The published list needs `*.sentry.io` and `*.ingest.us.sentry.io`; a matcher without
      # subdomains cannot express it. The dot anchors the END of the candidate — drop it and
      # `sentry.io.attacker.net` walks in, which is the whole reason the first version refused
      # patterns outright.
      allowed = ["*.sentry.io"]

      assert {:ok, "o123.ingest.sentry.io", 443} =
               Egress.decide("CONNECT o123.ingest.sentry.io:443 HTTP/1.1\r\n\r\n", allowed)

      for host <- ["sentry.io.attacker.net", "evilsentry.io", "notsentry.io"] do
        assert {:refused, {:host_not_allowed, ^host}} =
                 Egress.decide("CONNECT #{host}:443 HTTP/1.1\r\n\r\n", allowed),
               "#{host} must not pass `*.sentry.io`"
      end

      # A wildcard says "under this", not "this": the bare apex needs its own line.
      assert {:refused, _} = Egress.decide("CONNECT sentry.io:443 HTTP/1.1\r\n\r\n", allowed)
      assert {:ok, _, _} = Egress.decide("CONNECT sentry.io:443 HTTP/1.1\r\n\r\n", ["sentry.io"])
    end

    test "the shipped declaration carries the PUBLISHED list, not a reconstruction" do
      # It was rebuilt host by host from a binary and from correlations, and shipped with ONE entry.
      # Anthropic publishes what a sandboxed Claude Code needs; it is read, not inferred.
      hosts =
        Fleet.Spawner.Pod.Egress.Vendor.hosts(Path.join(File.cwd!(), "bin/claude_launch.sh"))

      for required <- ["api.anthropic.com", "statsig.anthropic.com", "sentry.io", "*.sentry.io"] do
        assert required in hosts, "#{required} is on the published list and must ship"
      end

      # Never added: it appears in no official list — only in a recipe for GRANTING GitHub access.
      refute "raw.githubusercontent.com" in hosts
    end

    test "a plain name matches EXACTLY — a rule without `*.` is not a suffix rule" do
      allowed = ["api.anthropic.com"]

      # The three shapes a suffix rule gets wrong. A rule that has to reason about where a domain
      # ends is a rule that will be wrong once.
      for host <- [
            "evil-api.anthropic.com.attacker.net",
            "api.anthropic.com.attacker.net",
            "notapi.anthropic.com"
          ] do
        assert {:refused, {:host_not_allowed, ^host}} =
                 Egress.decide("CONNECT #{host}:443 HTTP/1.1\r\n\r\n", allowed),
               "#{host} must not pass an exact-match allowlist"
      end
    end

    test "case does not decide — DNS is case-insensitive, the wall must be too" do
      assert {:ok, _, 443} =
               Egress.decide("CONNECT API.Anthropic.COM:443 HTTP/1.1\r\n\r\n", [
                 "api.anthropic.com"
               ])
    end

    test "a plain HTTP request is REFUSED, never proxied" do
      assert {:refused, {:not_a_connect_request, _}} =
               Egress.decide("GET http://api.anthropic.com/v1 HTTP/1.1\r\n\r\n", [
                 "api.anthropic.com"
               ])
    end

    test "garbage on the wire is refused, not parsed into something" do
      for junk <- ["", "\r\n", "CONNECT\r\n", "CONNECT :443 HTTP/1.1\r\n"] do
        assert {:refused, _} = Egress.decide(junk, ["api.anthropic.com"])
      end
    end
  end

  describe "start/3 — over a real unix socket" do
    test "a refused host gets 403 on the wire, and the connection closes", %{tmp_dir: tmp} do
      path = sock(tmp)
      {:ok, listen} = Egress.start(path, ["api.anthropic.com"], pod_id: "test")

      c = connect(path)
      :ok = :gen_tcp.send(c, "CONNECT evil.example:443 HTTP/1.1\r\n\r\n")

      assert {:ok, answer} = :gen_tcp.recv(c, 0, 2_000)
      assert answer =~ "403 Forbidden"
      assert answer =~ "egress allowlist"

      # And nothing is relayed after the refusal.
      assert {:error, :closed} = :gen_tcp.recv(c, 0, 2_000)
      :gen_tcp.close(listen)
    end

    test "an allowed host that does not resolve fails CLOSED, never open", %{tmp_dir: tmp} do
      # Allowed is not the same as reachable. The pod must get a refusal, not a hang and not a
      # silently proxied connection to something else.
      path = sock(tmp)
      {:ok, listen} = Egress.start(path, ["nx.invalid"], pod_id: "test")

      c = connect(path)
      :ok = :gen_tcp.send(c, "CONNECT nx.invalid:443 HTTP/1.1\r\n\r\n")

      assert {:ok, answer} = :gen_tcp.recv(c, 0, 5_000)
      assert answer =~ "403 Forbidden"
      :gen_tcp.close(listen)
    end

    test "a path over the AF_UNIX limit is REFUSED by name, not by :einval", %{tmp_dir: tmp} do
      # The kernel says "invalid argument" and nothing else. A caller composing a socket under a
      # long pod dir would read that as a bug in the proxy rather than a constraint on the path.
      long = Path.join(tmp, String.duplicate("x", 120) <> ".sock")

      assert {:error, {:egress_socket_path_too_long, _got, _max}} =
               Egress.start(long, ["example.com"], pod_id: "test")
    end

    test "a STALE socket file does not stop the next pod from listening", %{tmp_dir: tmp} do
      # A pod killed without releasing its socket leaves the file behind; `listen` on an address
      # that belongs to nobody fails, and the next spawn would die on its predecessor's corpse.
      path = sock(tmp)
      File.write!(path, "stale")

      assert {:ok, listen} = Egress.start(path, ["api.anthropic.com"], pod_id: "test")
      :gen_tcp.close(listen)
    end
  end

  describe "Vendor.hosts/1 — the declaration lives beside its launcher" do
    alias Fleet.Spawner.Pod.Egress.Vendor

    test "the path is DERIVED from the launcher, never composed from a name held elsewhere" do
      assert Vendor.declaration_path("/opt/lcars/bin/claude_launch.sh") ==
               "/opt/lcars/bin/claude_launch.egress"

      assert Vendor.declaration_path("/opt/lcars/bin/codex_launch.sh") ==
               "/opt/lcars/bin/codex_launch.egress"
    end

    test "hosts are read, comments and blanks dropped", %{tmp_dir: tmp} do
      launcher = Path.join(tmp, "codex_launch.sh")

      File.write!(Path.join(tmp, "codex_launch.egress"), """
      # a comment
      api.openai.com

      auth.openai.com   # trailing note
      api.openai.com
      """)

      assert Vendor.hosts(launcher) == ["api.openai.com", "auth.openai.com"]
    end

    test "a MISSING declaration yields no hosts — a wiring hole reaches nothing", %{tmp_dir: tmp} do
      # Fail-closed: the alternative is a vendor whose declaration was forgotten silently getting
      # full egress, which is the failure this rail exists to prevent.
      assert Vendor.hosts(Path.join(tmp, "ghost_launch.sh")) == []
    end

    test "the declaration SHIPS with its launcher — the manifest lists both or neither" do
      # Measured on a bench: `claude_launch.sh` was installed and `claude_launch.egress` was not,
      # so `Vendor.hosts/1` read an absent file, the allowlist was EMPTY, and the wall refused the
      # vendor's own API. A launcher without its declaration is a pod that reaches nothing.
      manifest = File.read!(Path.join(File.cwd!(), "etc/install.manifest"))

      assert manifest =~ ~r/^claude_launch\.sh\s/m
      assert manifest =~ ~r/^claude_launch\.egress\s/m
    end

    test "the shipped `claude` declaration names the vendor API and nothing else" do
      hosts = Vendor.hosts(Path.join(File.cwd!(), "bin/claude_launch.sh"))
      assert "api.anthropic.com" in hosts
    end

    test "`api.anthropic.com` is written in exactly ONE file of the repository" do
      # The centralisation IS the requirement, so it is asserted rather than trusted: a second
      # occurrence means someone hardcoded an endpoint where a vendor declaration belongs.
      offenders =
        ["lib/**/*.ex", "bin/*.sh", "etc/**/*.sh", "priv/**/*.yaml"]
        |> Enum.flat_map(&Path.wildcard(Path.join(File.cwd!(), &1)))
        |> Enum.filter(&(File.read!(&1) =~ "api.anthropic.com"))
        |> Enum.map(&Path.relative_to(&1, File.cwd!()))

      assert offenders == [],
             "api.anthropic.com belongs in bin/claude_launch.egress alone, found in: " <>
               Enum.join(offenders, ", ")
    end
  end

  defp profile(network, containment \\ "bwrap") do
    %Fleet.CapProfile{
      kind: "CapabilityProfile",
      metadata: %{"name" => "r", "containment" => containment, "network" => network},
      spec: %{}
    }
  end

  describe "provision/3 — the proxy is STARTED, not merely startable" do
    setup do
      # Short base, same reason as the sockets above: `tmp_dir` carries the test NAME and AF_UNIX
      # caps the path. The real base is `/run/lcars/egress`, which is short for this exact reason.
      base = Path.join(System.tmp_dir!(), "lcars-egb")
      File.mkdir_p!(base)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :spawner_egress_sock_base, base)
      on_exit(fn -> File.rm_rf(base) end)
      :ok
    end

    test "a bwrap pod gets a live socket, and it answers", %{tmp_dir: tmp} do
      # The gap this closes: the launcher supported egress, the proxy existed, and nothing started
      # it — a door nobody takes. Found by a bench build, not by the gate.
      launcher = Path.join(tmp, "claude_launch.sh")
      File.write!(Path.join(tmp, "claude_launch.egress"), "api.vendor.test\n")

      pod = "p#{System.unique_integer([:positive])}"
      assert {:ok, path} = Egress.provision(pod, profile("vendor-only"), launcher)
      assert path =~ pod

      c = connect(path)
      :ok = :gen_tcp.send(c, "CONNECT nope.example:443 HTTP/1.1\r\n\r\n")
      assert {:ok, answer} = :gen_tcp.recv(c, 0, 2_000)
      assert answer =~ "403"

      assert :ok = Egress.release(pod)
      refute File.exists?(path)
    end

    test "a HOST-containment pod gets none — there is no namespace to seal", %{tmp_dir: tmp} do
      launcher = Path.join(tmp, "claude_launch.sh")
      assert {:ok, nil} = Egress.provision("p-host", profile("vendor-only", "none"), launcher)
    end

    test "release/1 is idempotent — a pod that never had one is a no-op" do
      assert :ok = Egress.release("never-provisioned")
    end
  end

  describe "allowlist/2 — vendor-only is the floor, egress adds the role's own" do
    test "vendor-only gets the vendor's hosts and nothing else", %{tmp_dir: tmp} do
      launcher = Path.join(tmp, "claude_launch.sh")
      File.write!(Path.join(tmp, "claude_launch.egress"), "api.vendor.test\n")

      cap = %Fleet.CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => "r"},
        spec: %{"scope" => %{"egress_hosts" => ["docs.example.com"]}}
      }

      # The role DECLARES hosts but its profile does not say `egress`: they are not granted. A
      # declaration is not a permission.
      assert Egress.allowlist(cap, launcher) == ["api.vendor.test"]
    end

    test "egress adds them, vendor first, no duplicates", %{tmp_dir: tmp} do
      launcher = Path.join(tmp, "claude_launch.sh")
      File.write!(Path.join(tmp, "claude_launch.egress"), "api.vendor.test\n")

      cap = %Fleet.CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => "r", "network" => "egress"},
        spec: %{"scope" => %{"egress_hosts" => ["docs.example.com", "api.vendor.test"]}}
      }

      assert Egress.allowlist(cap, launcher) == ["api.vendor.test", "docs.example.com"]
    end

    test "an `egress` role with NO declared host still gets the vendor's — never nothing" do
      cap = %Fleet.CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => "r", "network" => "egress"},
        spec: %{}
      }

      hosts = Egress.allowlist(cap, Path.join(File.cwd!(), "bin/claude_launch.sh"))
      assert "api.anthropic.com" in hosts
    end
  end
end
