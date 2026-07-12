defmodule Fleet.Pilot.PollerGiteaKickTest do
  @moduledoc """
  Z6e (D-13, 2026-07-13) — le webhook gitea.* comme ACCÉLÉRATEUR de poll.

  Contrat testé : un event gitea.* reçu par le Poller programme UN poll accéléré
  (`:gitea_kick`, coalescence `@gitea_kick_debounce_ms`) — une rafale = un poll ;
  le kick ne touche PAS la chaîne de ticks (pas de `:poll` injecté) ; un event
  non-gitea ne kicke rien. Le subscribe Bus lui-même est opt-in (défaut false,
  câblé par Application.step_children!) — ici on teste la MÉCANIQUE du handler
  par envoi direct (l'abonnement n'est que la source du message).
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.Poller

  defmodule EmptyOrgForge do
    # Org vide : le poll « réussit à ne rien faire » — on ne teste QUE la mécanique du kick.
    def list_org_repos(_org, _opts), do: {:ok, []}
  end

  # La fenêtre de coalescence du Poller est 1_000 ms — marge pour l'async CI.
  @debounce_wait 1_400

  defp start_poller!(name) do
    {:ok, pid} =
      Poller.start_link(
        name: name,
        human: "test-human",
        start_tick?: false,
        step_dispatch?: true,
        forge_client: EmptyOrgForge,
        forge_opts: []
      )

    pid
  end

  defp gitea_event(type) do
    %Fleet.Event{source: :event_router, type: type, timestamp: DateTime.utc_now()}
  end

  test "une rafale d'events gitea.* = UN poll (coalescence :gitea_kick)" do
    pid = start_poller!(:gitea_kick_burst_poller)
    assert %{poll_count: 0} = Poller.stats(pid)

    for _ <- 1..5, do: send(pid, gitea_event(:"gitea.issue"))
    Process.sleep(@debounce_wait)

    # 5 events dans la fenêtre → exactement 1 poll, et le flag est retombé
    assert %{poll_count: 1} = Poller.stats(pid)

    # rafale suivante → le kick repart (le flag n'est pas resté collé)
    send(pid, gitea_event(:"gitea.pull_request"))
    Process.sleep(@debounce_wait)
    assert %{poll_count: 2} = Poller.stats(pid)
  end

  test "un event non-gitea ne kicke RIEN (le hint est scopé au préfixe gitea.)" do
    pid = start_poller!(:gitea_kick_scoped_poller)

    send(pid, gitea_event(:"pod.completed"))
    send(pid, gitea_event(:"work_item.completed"))
    Process.sleep(@debounce_wait)

    assert %{poll_count: 0} = Poller.stats(pid)
  end
end
