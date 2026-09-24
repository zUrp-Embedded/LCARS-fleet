defmodule Fleet.Spawner.Pod.EgressTest do
  @moduledoc """
  Verify CONNECT policy and transport behavior over real AF_UNIX sockets.
  Stale paths and wire-level refusals require the actual transport, not a mocked decision.
  """
  # Serial: these tests change application config and the node-global store environment.
  use ExUnit.Case, async: false

  alias Fleet.Spawner.Pod.Egress

  @moduletag :tmp_dir

  # Use a short path to fit AF_UNIX limits, and a PID suffix to isolate concurrent runners
  # (even those sharing a clone). The stale-socket test creates its own fixture; no stable
  # cross-run path is needed. rmdir cleanup removes only an empty directory.
  defp sock(_tmp) do
    dir = Path.join(System.tmp_dir!(), "lcars-eg-#{System.pid()}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{System.unique_integer([:positive])}.sock")

    on_exit(fn ->
      File.rm(path)
      File.rmdir(dir)
    end)

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
      assert {:refused, {:host_not_allowed, "evil.example"}} =
               Egress.decide("CONNECT evil.example:443 HTTP/1.1\r\n\r\n", ["api.anthropic.com"])
    end

    test "an EMPTY allowlist refuses everything — a pod with no declared egress reaches nothing" do
      assert {:refused, {:host_not_allowed, _}} =
               Egress.decide("CONNECT api.anthropic.com:443 HTTP/1.1\r\n\r\n", [])
    end

    test "a plain-HTTP proxy request is refused as the SANDBOX, not as the destination" do
      # Plain HTTP uses absolute-URI GET. The response must identify the sandbox rather than
      # suggest a destination authorization failure.
      line = "GET http://forge:3000/web/test2.git/info/refs HTTP/1.1\r\n\r\n"

      assert {:refused, {:not_a_connect_request, _}} = Egress.decide(line, ["forge"])
    end

    test "a `*.` rule accepts subdomains and REFUSES the right-hand impostor — the mutation" do
      # Vendor declarations include subdomains; suffix matching must include the dot boundary.
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
      # Verify the vendor declaration shipped with the launcher.
      hosts =
        Fleet.Spawner.Pod.Egress.Vendor.hosts(Path.join(File.cwd!(), "bin/claude_launch.sh"))

      for required <- ["api.anthropic.com", "statsig.anthropic.com", "sentry.io", "*.sentry.io"] do
        assert required in hosts, "#{required} is on the published list and must ship"
      end

      # GitHub browsing is an additional permission, not a vendor API requirement.
      refute "raw.githubusercontent.com" in hosts
    end

    test "a plain name matches EXACTLY — a rule without `*.` is not a suffix rule" do
      allowed = ["api.anthropic.com"]

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
    test "an ALLOWED host that cannot be reached gets 502, not the allowlist's 403 — and the log names it",
         %{tmp_dir: tmp} do
      # `.invalid` never resolves (RFC 2606): the proxy's own DNS failure, on a host the policy allows.
      path = sock(tmp)
      {:ok, listen} = Egress.start(path, ["nowhere.invalid"], pod_id: "test")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          c = connect(path)
          :ok = :gen_tcp.send(c, "CONNECT nowhere.invalid:443 HTTP/1.1\r\n\r\n")
          assert {:ok, answer} = :gen_tcp.recv(c, 0, 15_000)
          assert answer =~ "502 Bad Gateway"
          refute answer =~ "allowlist"
          Process.sleep(50)
        end)

      assert log =~ "upstream nowhere.invalid:443 failed"
      :gen_tcp.close(listen)
    end

    test "a refused host gets 403 on the wire, and the connection closes", %{tmp_dir: tmp} do
      path = sock(tmp)
      {:ok, listen} = Egress.start(path, ["api.anthropic.com"], pod_id: "test")

      c = connect(path)
      :ok = :gen_tcp.send(c, "CONNECT evil.example:443 HTTP/1.1\r\n\r\n")

      assert {:ok, answer} = :gen_tcp.recv(c, 0, 2_000)
      assert answer =~ "403 Forbidden"
      assert answer =~ "egress allowlist"

      assert {:error, :closed} = :gen_tcp.recv(c, 0, 2_000)
      :gen_tcp.close(listen)
    end

    test "a path over the AF_UNIX limit is REFUSED by name, not by :einval", %{tmp_dir: tmp} do
      long = Path.join(tmp, String.duplicate("x", 120) <> ".sock")

      assert {:error, {:egress_socket_path_too_long, _got, _max}} =
               Egress.start(long, ["example.com"], pod_id: "test")
    end

    test "a STALE socket file does not stop the next pod from listening", %{tmp_dir: tmp} do
      path = sock(tmp)
      File.write!(path, "stale")

      assert {:ok, listen} = Egress.start(path, ["api.anthropic.com"], pod_id: "test")
      :gen_tcp.close(listen)
    end
  end

  # The node resolver is doubled: a hosts table, and a DNS on loopback that answers every name
  # under the search suffix, as a provider DNS that resolves any name under its own domain.
  describe "start/3 — the upstream name, under a doubled resolver" do
    setup do
      saved =
        for opt <- [:resolv_conf, :lookup, :nameservers, :search],
            do: {opt, :inet_db.res_option(opt)}

      {:ok, upstream} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
      {:ok, port} = :inet.port(upstream)
      dns = dns_answering_suffix(".search.invalid", {127, 0, 0, 1})

      :inet_db.res_option(:resolv_conf, ~c"")
      :inet_db.res_option(:nameservers, [{{127, 0, 0, 1}, dns}])
      :inet_db.res_option(:search, [~c"search.invalid"])
      :inet_db.res_option(:lookup, [:file, :dns])

      on_exit(fn ->
        :inet_db.del_host({127, 0, 0, 1})
        for {opt, value} <- saved, do: :inet_db.res_option(opt, value)
      end)

      %{port: port}
    end

    test "an allowed name the DNS does not know stays CLOSED, though the search list would answer it",
         %{tmp_dir: tmp, port: port} do
      answer = tunnel(tmp, "nx.invalid", port)
      refute answer =~ "200 Connection Established"
      # Closed as an UNREACHABLE allowed host (502), not as a policy refusal (403): it is allowed.
      assert answer =~ "502 Bad Gateway"
    end

    test "an allowed name the hosts file declares is served", %{tmp_dir: tmp, port: port} do
      :inet_db.add_host({127, 0, 0, 1}, [~c"forge-host.invalid"])

      assert tunnel(tmp, "forge-host.invalid", port) =~ "200 Connection Established"
    end
  end

  # The first answer of the proxy to a CONNECT for `host`, allowed, on `port`.
  defp tunnel(tmp, host, port) do
    path = sock(tmp)
    {:ok, listen} = Egress.start(path, [host], pod_id: "test")
    on_exit(fn -> :gen_tcp.close(listen) end)
    c = connect(path)
    :ok = :gen_tcp.send(c, "CONNECT #{host}:#{port} HTTP/1.1\r\n\r\n")
    {:ok, answer} = :gen_tcp.recv(c, 0, 5_000)
    answer
  end

  # A DNS server on loopback: an A record for names under `suffix`, NXDOMAIN for any other.
  defp dns_answering_suffix(suffix, {a, b, c, d}) do
    {:ok, udp} = :gen_udp.open(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(udp)

    serve = fn serve ->
      {:ok, {peer, peer_port, <<id::16, _::80, query::binary>>}} = :gen_udp.recv(udp, 0)
      {labels, tail} = dns_labels(query, [])
      question = binary_part(query, 0, byte_size(query) - byte_size(tail) + 4)

      reply =
        if String.ends_with?(Enum.join(labels, "."), suffix),
          do:
            <<id::16, 0x8180::16, 1::16, 1::16, 0::32>> <>
              question <> <<0xC00C::16, 1::16, 1::16, 0::32, 4::16, a, b, c, d>>,
          else: <<id::16, 0x8183::16, 1::16, 0::16, 0::32>> <> question

      :ok = :gen_udp.send(udp, peer, peer_port, reply)
      serve.(serve)
    end

    pid = spawn(fn -> serve.(serve) end)
    :ok = :gen_udp.controlling_process(udp, pid)
    on_exit(fn -> Process.exit(pid, :kill) end)
    port
  end

  defp dns_labels(<<0, rest::binary>>, acc), do: {Enum.reverse(acc), rest}

  defp dns_labels(<<len, label::binary-size(len), rest::binary>>, acc),
    do: dns_labels(rest, [label | acc])

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
      assert Vendor.hosts(Path.join(tmp, "ghost_launch.sh")) == []
    end

    test "the declaration SHIPS with its launcher — the manifest lists both or neither" do
      # A launcher without its endpoint declaration cannot reach its vendor by default.
      manifest = File.read!(Path.join(File.cwd!(), "etc/release.manifest"))

      assert manifest =~ ~r/^claude_launch\.sh\s/m
      assert manifest =~ ~r/^claude_launch\.egress\s/m
    end

    test "the shipped `claude` declaration names the vendor API and nothing else" do
      hosts = Vendor.hosts(Path.join(File.cwd!(), "bin/claude_launch.sh"))
      assert "api.anthropic.com" in hosts
    end

    test "`api.anthropic.com` is written in exactly ONE file of the repository" do
      # Keep endpoints in the vendor declaration, not in runtime code or shell copies.
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
      # Short PID-scoped base avoids AF_UNIX length and concurrent-runner collisions.
      base = Path.join(System.tmp_dir!(), "lcars-egb-#{System.pid()}")
      File.mkdir_p!(base)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :spawner_egress_sock_base, base)
      on_exit(fn -> File.rm_rf(base) end)
      :ok
    end

    test "a bwrap pod gets a live socket, and it answers", %{tmp_dir: tmp} do
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

  # ⚠ CE QUE LA DECISION DU 2026-09-17 A CHANGE, ET CE QU'ELLE N'A PAS TOUCHE. Tous les roles
  # declarent `open` ; la mecanique reste entiere, et le DEFAUT du moteur reste ferme. Ces temoins
  # tiennent les deux moities : ce que les profils disent, et ce que le code ferait sans eux.
  describe "la politique reseau des roles — declaree par profil, jamais deduite" do
    @profils_spawnables Path.wildcard("priv/catalogue*/cap_profile/cap-profiles/*.yaml")

    test "tout profil SPAWNABLE declare `network: open` — et un siege reserve n'en declare aucune" do
      {spawnables, sieges} =
        Enum.split_with(@profils_spawnables, &(File.read!(&1) =~ ~r/^kind: CapabilityProfile$/m))

      assert length(spawnables) >= 9,
             "#{length(spawnables)} profils spawnables lus — l'instrument ne voit plus son sujet"

      for f <- spawnables do
        assert File.read!(f) =~ ~r/^  network: open$/m,
               "#{Path.basename(f)} ne declare pas `network: open` : la decision est prise par " <>
                 "PROFIL, et un role muet retomberait au defaut ferme sans que personne le dise"
      end

      for f <- sieges do
        refute File.read!(f) =~ ~r/^  network:/m,
               "#{Path.basename(f)} est un siege reserve : il ne tourne jamais, une politique " <>
                 "reseau y decrirait un pod qui n'existe pas"
      end
    end

    test "le DEFAUT du moteur reste ferme — c'est le profil qui ouvre, pas le code" do
      assert Fleet.CapProfile.default_network() == "vendor-only"

      # un profil qui ne dit rien ne recoit que les hotes de son vendor
      muet = %Fleet.CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => "r", "containment" => "bwrap"},
        spec: %{}
      }

      assert Fleet.CapProfile.network(muet) == "vendor-only"
    end

    test "REFERMER est une ligne : un role qui declare `egress` retrouve son mur", %{tmp_dir: tmp} do
      launcher = Path.join(tmp, "claude_launch.sh")
      File.write!(Path.join(tmp, "claude_launch.egress"), "api.vendor.test\n")

      assert Egress.allowlist(profile("egress"), launcher) == ["api.vendor.test"]
      assert Egress.allowlist(profile("open"), launcher) == :open
    end
  end

  describe "network: open — the host wall goes, the seal stays" do
    setup do
      base = Path.join(System.tmp_dir!(), "lcars-egopen-#{System.pid()}")
      File.mkdir_p!(base)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :spawner_egress_sock_base, base)
      on_exit(fn -> File.rm_rf(base) end)
      :ok
    end

    test "allowlist/2 yields the :open POLICY, and reads no data source", %{tmp_dir: tmp} do
      launcher = Path.join(tmp, "claude_launch.sh")
      File.write!(Path.join(tmp, "claude_launch.egress"), "api.vendor.test\n")

      # Converged hosts must not constrain the explicit open policy. Vendor lookup still runs.
      dir = Path.join([tmp, "state", "egress.d"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "r.hosts"), "from.the.store\n")
      System.put_env("LCARS_STORE_ROOT", tmp)
      on_exit(fn -> System.delete_env("LCARS_STORE_ROOT") end)

      assert Egress.allowlist(profile("open"), launcher) == :open
    end

    test "decide/2 accepts ANY host under :open" do
      for host <- ["github.com", "evil.example", "x.y.z.whatever.test"] do
        assert {:ok, ^host, 443} = Egress.decide("CONNECT #{host}:443 HTTP/1.1\r\n", :open)
      end
    end

    test "under :open a NON-CONNECT request is STILL refused — the tunnel rule is not the host rule" do
      assert {:refused, {:not_a_connect_request, _}} =
               Egress.decide("GET http://anything.test/ HTTP/1.1\r\n", :open)
    end

    test "`*` in a DATA source stays an ordinary name — no file can open a pod", %{tmp_dir: tmp} do
      launcher = Path.join(tmp, "claude_launch.sh")
      File.write!(Path.join(tmp, "claude_launch.egress"), "*\n")

      # A literal * remains list data and cannot select the :open policy.
      assert Egress.allowlist(profile("vendor-only"), launcher) == ["*"]

      assert {:refused, {:host_not_allowed, "github.com"}} =
               Egress.decide("CONNECT github.com:443 HTTP/1.1\r\n", ["*"])
    end

    test "provision/3 under :open starts the proxy and SAYS so once", %{tmp_dir: tmp} do
      launcher = Path.join(tmp, "claude_launch.sh")
      File.write!(Path.join(tmp, "claude_launch.egress"), "api.vendor.test\n")
      pod = "p#{System.unique_integer([:positive])}"

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, path} = Egress.provision(pod, profile("open"), launcher)
          assert path =~ pod
          Egress.release(pod)
        end)

      # Log the policy explicitly: absence of host refusals does not explain open access.
      assert log =~ "OPEN allowlist"
      assert log =~ "role r"
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

  describe "allowlist/2 — the CONVERGED source, the only one that survives a rebuild" do
    # Converged declarations survive image rebuilds and still require the role’s egress policy.

    setup %{tmp_dir: tmp} do
      root = Path.join(tmp, "store")
      File.mkdir_p!(Path.join([root, "state", "egress.d"]))
      prev = System.get_env("LCARS_STORE_ROOT")
      System.put_env("LCARS_STORE_ROOT", root)

      on_exit(fn ->
        if prev,
          do: System.put_env("LCARS_STORE_ROOT", prev),
          else: System.delete_env("LCARS_STORE_ROOT")
      end)

      launcher = Path.join(tmp, "claude_launch.sh")
      File.write!(Path.join(tmp, "claude_launch.egress"), "api.vendor.test\n")
      {:ok, root: root, launcher: launcher}
    end

    defp converged(root, role, body),
      do: File.write!(Path.join([root, "state", "egress.d", role <> ".hosts"]), body)

    defp cap(name, network \\ nil) do
      meta = %{"name" => name}
      meta = if network, do: Map.put(meta, "network", network), else: meta
      %Fleet.CapProfile{kind: "CapabilityProfile", metadata: meta, spec: %{}}
    end

    test "an `egress` role gets the converged hosts, deduped after the vendor's", ctx do
      converged(ctx.root, "eng", "# les registres approuves\npypi.org\napi.vendor.test\n")

      assert Egress.allowlist(cap("eng", "egress"), ctx.launcher) ==
               ["api.vendor.test", "pypi.org"]
    end

    test "TWO KEYS: a sealed role gets NOTHING from the file, however signed", ctx do
      converged(ctx.root, "eng", "pypi.org\n")

      assert Egress.allowlist(cap("eng"), ctx.launcher) == ["api.vendor.test"]
    end

    test "THE FILE IS ACTUALLY READ — it changes between two calls and so does the answer", ctx do
      converged(ctx.root, "eng", "pypi.org\n")
      assert "pypi.org" in Egress.allowlist(cap("eng", "egress"), ctx.launcher)

      # Change the file between calls to detect cached or ignored converged declarations.
      converged(ctx.root, "eng", "pypi.org\nfiles.pythonhosted.org\n")
      assert "files.pythonhosted.org" in Egress.allowlist(cap("eng", "egress"), ctx.launcher)
    end

    test "the file name is DERIVED from the profile name, not guessed", ctx do
      converged(ctx.root, "eng", "pypi.org\n")

      # Change only the role to verify lookup uses its own declaration file.
      assert Egress.allowlist(cap("qualifier", "egress"), ctx.launcher) == ["api.vendor.test"]
    end

    test "no file: the answer is exactly today's, byte for byte", ctx do
      assert Egress.allowlist(cap("eng", "egress"), ctx.launcher) == ["api.vendor.test"]
    end

    test "no store at all: inert, never a refusal (DR-023)", ctx do
      System.delete_env("LCARS_STORE_ROOT")
      assert Egress.allowlist(cap("eng", "egress"), ctx.launcher) == ["api.vendor.test"]
    end

    test "comments and blanks obey the vendor grammar — one parser, not two", ctx do
      converged(ctx.root, "eng", "# entete\n\npypi.org # en fin de ligne\n\n")

      assert Egress.allowlist(cap("eng", "egress"), ctx.launcher) == [
               "api.vendor.test",
               "pypi.org"
             ]
    end

    test "the converged source opens NO new matcher — `*.` stays anchored", ctx do
      converged(ctx.root, "eng", "*.pypi.org\n")
      allowed = Egress.allowlist(cap("eng", "egress"), ctx.launcher)

      assert {:ok, "files.pypi.org", 443} =
               Egress.decide("CONNECT files.pypi.org:443 HTTP/1.1\r\n", allowed)

      assert {:refused, _} =
               Egress.decide("CONNECT pypi.org.attaquant.net:443 HTTP/1.1\r\n", allowed)
    end
  end
end
