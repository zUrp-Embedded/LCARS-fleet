defmodule Fleet.Spawner.PodTmuxTest do
  use ExUnit.Case, async: true

  alias Fleet.Spawner.PodTmux

  # Conventions PARTAGÉES avec bin/bwrap_launch.sh : si elles divergent, le host tape un sock que le pod
  # n'a pas créé (kick muet). Ce test verrouille l'accord des deux côtés.
  describe "conventions sock/session (accord avec bwrap_launch.sh)" do
    test "session_name = lcars-pod-<pod_id>" do
      assert PodTmux.session_name("pod-42") == "lcars-pod-pod-42"
    end

    test "sock_path = <base>/<pod_id>/pod.sock (filename constant)" do
      base = PodTmux.sock_base()
      assert PodTmux.sock_path("pod-42") == Path.join([base, "pod-42", "pod.sock"])
    end

    test "sock_path tient sous la limite sun_path (108o) pour un pod_id UUID (C3 régression)" do
      uuid = "f0b6c95c-c6d7-466c-97b2-283fcaf67fb2"
      path = PodTmux.sock_path(uuid)
      # avant fix : <base>/<uuid>/lcars-pod-<uuid>.sock = 109 > 108 → "File name too long"
      assert byte_size(path) < 108, "sock_path trop long (#{byte_size(path)}o) : #{path}"
    end

    test "sock_base a un défaut non-vide (l'accord avec les launchers = l'export LCARS_TMUX_SOCK_BASE, pas l'égalité des défauts)" do
      assert is_binary(PodTmux.sock_base())
      assert PodTmux.sock_base() != ""
    end
  end

  # ENTER manqué vu LIVE (2026-06-20) : texte+Enter batchés en un seul send = le TUI claude rate la
  # soumission. Le contrat « 2 sends, texte littéral PUIS Enter » est verrouillé ici (anti-régression d'une
  # "simplification" qui recombinerait les deux et réintroduirait la flakiness).
  describe "send_keys_args/2 (robustesse ENTER — 2 sends distincts)" do
    test "texte LITTÉRAL (-l) d'abord, puis Enter en send séparé" do
      assert [
               ["send-keys", "-t", "lcars-pod-pod-42", "-l", "wake"],
               ["send-keys", "-t", "lcars-pod-pod-42", "Enter"]
             ] = PodTmux.send_keys_args("pod-42", "wake")
    end

    test "le texte n'est JAMAIS combiné avec Enter dans le même send (la régression d'hier)" do
      [text_args, enter_args] = PodTmux.send_keys_args("pod-1", "yop")
      refute "Enter" in text_args
      assert List.last(enter_args) == "Enter"
    end
  end

  # F-034 : `pkill -f` ancré + échappé + garde anti mass-kill.
  describe "pkill_pattern/1 (F-034 anti self-kill)" do
    test "pod_id valide → pattern ancré en token (matche le holder, exclut les sur-matchs)" do
      assert {:ok, pat} = PodTmux.pkill_pattern("pr-8-engineer")
      {:ok, re} = Regex.compile(pat)

      # le holder porte le pod_id comme arg STANDALONE (bwrap_launch.sh <role> <pod_id> ...) → matche.
      assert Regex.match?(re, "bwrap a pr-8-engineer /home/x/pods/pr-8-engineer claude")

      # holder HOST : argv0 `lcars-hold:<role>:<pod_id>` (F-HOLDER-LEAK) — le `:` avant le pod_id fait
      # rater l'ancrage token seul ; l'alternation `lcars-hold:<role>:` le rattrape.
      assert Regex.match?(re, "lcars-hold:engineer:pr-8-engineer infinity")
      # superstring (pod_id préfixe d'un autre) → PAS de match (ancrage token), DEUX formes.
      refute Regex.match?(re, "bwrap a pr-8-engineer-v2 /x claude")
      refute Regex.match?(re, "lcars-hold:engineer:pr-8-engineer-v2 infinity")
      # substring noyé (pas un token) → PAS de match.
      refute Regex.match?(re, "xxpr-8-engineerxx")
    end

    test "métacaractères regex échappés (pas de sur-match)" do
      assert {:ok, pat} = PodTmux.pkill_pattern("pod.v1.2")
      {:ok, re} = Regex.compile(pat)
      assert Regex.match?(re, "x pod.v1.2 y")
      # `.` échappé → ne matche pas un caractère quelconque.
      refute Regex.match?(re, "x podXv1X2 y")
    end

    test "pod_id vide/anormal → :unsafe (pkill -f SKIP, anti mass-kill du BEAM)" do
      for bad <- ["", "   ", "ab", "a b", "x;rm -rf", "../etc", "-foo"] do
        assert :unsafe = PodTmux.pkill_pattern(bad), "pod_id #{inspect(bad)}"
      end
    end
  end
end
