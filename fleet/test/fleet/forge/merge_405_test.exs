defmodule Fleet.Forge.Client.Merge405Test do
  use ExUnit.Case, async: true

  alias Fleet.Forge.Client, as: ForgeClient

  @moduledoc """
  LE 405 DE GITEA PORTE DEUX FAITS OPPOSÉS SOUS LE MÊME LIBELLÉ — mesuré, pas supposé.

  `fleet/probe-rails#24`, 2026-08-18 : conflit git réel et définitif (`git merge-tree` →
  `CONFLICT (content): journal.txt`), et la forge répond
  `405 {"message":"Please try again later"}` — le message réservé au calcul en cours.

  Le commentaire qui vivait au-dessus de ce code avait DÉJÀ nommé la cohabitation des deux faits,
  en supposant que le libellé anglais les séparait. **Sa propre prémisse était le contre-exemple.**
  Coût mesuré : 1447 tentatives en 21 h, ~2880 requêtes/jour, et 1,6 s de `sleep` à chaque tick.

  Le libellé n'est pas fiable ; l'état l'est.
  """

  defmodule Forge do
    @moduledoc false
    @behaviour Plug

    @impl Plug
    def init(mergeable), do: mergeable

    @impl Plug
    def call(conn, mergeable) do
      send(self(), {:hit, conn.method, conn.request_path})

      {status, body} =
        case conn.method do
          "POST" -> {405, %{"message" => "Please try again later"}}
          "GET" -> {200, %{"mergeable" => mergeable, "state" => "open", "merged" => false}}
        end

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.send_resp(status, JSON.encode!(body))
    end
  end

  defp merge(mergeable) do
    ForgeClient.merge_pr("fleet/p", 24,
      base_url: "http://fake.test",
      token: "t",
      merge_retry_delay_ms: 0,
      req_options: [plug: {Forge, mergeable}]
    )
  end

  defp posts do
    Stream.repeatedly(fn ->
      receive do
        {:hit, m, p} -> {m, p}
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(&(&1 != nil))
    |> Enum.count(fn {m, _} -> m == "POST" end)
  end

  test "405 « try again later » MAIS `mergeable: false` → UNE tentative, et un blocage nommé" do
    assert {:error, {:merge_blocked, %{"message" => _}}} = merge(false)

    # ⚠ L'ASSERTION QUI PORTE TOUT LE CORRECTIF. Trois tentatives et deux `sleep` étaient payés à
    # CHAQUE tick du pilote pour un résultat connu d'avance — et le tick externe relançait
    # indéfiniment ce que la borne interne bornait. Bornée dans le code, infinie en pratique.
    assert posts() == 1
  end

  test "TÉMOIN — 405 « try again later » et `mergeable: true` → les tentatives ont bien lieu" do
    # Sans ce témoin, un correctif qui aurait supprimé le retry PARTOUT passerait le test ci-dessus
    # en ne prouvant rien. Le transitoire existe : une PR dont la mergeabilité se recalcule doit
    # encore être réessayée, et l'erreur reste celle d'avant.
    assert {:error, {:http, 405, _}} = merge(true)
    assert posts() == 3
  end

  test "état ILLISIBLE → on retente, jamais un blocage tiré d'une absence de réponse" do
    # Se tromper vers le retry coûte une tentative ; se tromper vers le blocage annoncerait un
    # conflit sur une forge qui n'a simplement pas répondu, et enverrait un producteur réparer ce
    # qui n'est pas cassé.
    defmodule Silent do
      @moduledoc false
      @behaviour Plug
      @impl Plug
      def init(o), do: o
      @impl Plug
      def call(conn, _) do
        send(self(), {:hit, conn.method, conn.request_path})

        case conn.method do
          "POST" ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.send_resp(405, JSON.encode!(%{"message" => "Please try again later"}))

          "GET" ->
            Plug.Conn.send_resp(conn, 500, "boom")
        end
      end
    end

    assert {:error, {:http, 405, _}} =
             ForgeClient.merge_pr("fleet/p", 24,
               base_url: "http://fake.test",
               token: "t",
               merge_retry_delay_ms: 0,
               req_options: [plug: {Silent, nil}]
             )

    assert posts() == 3
  end
end
