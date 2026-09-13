defmodule Mix.CoverOtp27Test do
  @moduledoc """
  L'outil de couverture sous OTP 27 : la sonde NOMME ce que cover refuse, la confrontation ROUGIT
  quand la liste declaree ne colle plus, et `mix.exs` porte la porte.

  ⚠ CE FICHIER EST LIE A OTP 27, ET C'EST VOULU. Le premier temoin fabrique un module que cover
  refuse sous OTP 27 (erlang/otp#11524) ; sous OTP >= 28.4 cover l'accepte, le temoin rougit, et ce
  rouge DIT quoi faire : retirer `tool:` et `otp27_refused:` de `mix.exs`, supprimer
  `test/support/cover_otp27.ex` et ce fichier. Un temoin qui resterait vert sur un outil devenu
  inutile laisserait douze modules hors mesure pour rien.
  """
  use ExUnit.Case, async: true

  alias Fleet.Test.CoverOtp27

  # La forme mesuree le 2026-09-12 : deux `in` sur des listes litterales, une EXPRESSION a gauche
  # de chacun, relies par `and`. Sous OTP 27, `sys_coverage` nomme ses temporaires `_N` et entre en
  # collision avec ceux que le compilateur Elixir a poses pour ces `in`.
  @crash ~S"""
  defmodule CoverOtp27Witness.Crash do
    @allowed ~w(a b)
    def g(m), do: Map.get(m, "k") in @allowed and Map.get(m, "j") in [nil, 0]
  end
  """

  @clean ~S"""
  defmodule CoverOtp27Witness.Clean do
    def g(x), do: x
  end
  """

  # Des beams FABRIQUES dans un ebin jetable : la sonde lit un repertoire, elle ne sait rien du
  # depot. ⚠ PAR `elixirc`, PAS PAR `Code.compile_string/1` : mesure du 2026-09-12, ce dernier
  # rend ici un beam SANS `debug_info` (`{:error, {:no_abstract_code, _}}` chez cover), et charge
  # le module dans CE VM. `elixirc` emet le chunk et ne charge rien.
  defp ebin(sources) do
    dir = Fleet.TestEnv.tmp_path("cover_otp27")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    elixirc = System.find_executable("elixirc") || flunk("elixirc introuvable sur le PATH")

    for {src, i} <- Enum.with_index(sources) do
      file = Path.join(dir, "src#{i}.ex")
      File.write!(file, src)
      {_, 0} = System.cmd(elixirc, ["-o", dir, file], stderr_to_stdout: true)
    end

    dir
  end

  describe "probe/1 — ce que cover refuse, et rien d'autre" do
    test "le module qui fait crasher cover est nomme ; le module sain ne l'est pas" do
      assert CoverOtp27.probe(ebin([@crash, @clean])) == [CoverOtp27Witness.Crash]
    end

    test "un ebin sans beam est une PANNE D'INSTRUMENT, jamais « zero refus »" do
      dir = Fleet.TestEnv.tmp_path("cover_otp27_vide")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      assert_raise Mix.Error, ~r/aucun beam .* INCONNUE/, fn -> CoverOtp27.probe(dir) end
    end
  end

  describe "confront!/2 — la liste declaree est un cliquet, dans les deux sens" do
    test "un refus NON declare rougit et nomme le module (il sortirait de la mesure en silence)" do
      assert_raise Mix.Error, ~r/NON declares[^\n]*CoverOtp27Witness\.Crash/, fn ->
        CoverOtp27.confront!([CoverOtp27Witness.Crash], [])
      end
    end

    test "un declare que cover ACCEPTE rougit aussi — c'est le signal de retirer l'outil" do
      assert_raise Mix.Error, ~r/ACCEPTE maintenant[^\n]*CoverOtp27Witness\.Crash/, fn ->
        CoverOtp27.confront!([], [CoverOtp27Witness.Crash])
      end
    end

    test "la meme liste, dans un autre ordre, est un accord" do
      assert :ok = CoverOtp27.confront!([B, A], [A, B])
    end
  end

  describe "plan/2 — ce qui sera compile est tout SAUF les declares, et seulement si la sonde est d'accord" do
    test "les beams rendus excluent le declare et gardent le sain" do
      dir = ebin([@crash, @clean])

      assert [beam] = CoverOtp27.plan(dir, [CoverOtp27Witness.Crash])
      assert Path.basename(beam) == "Elixir.CoverOtp27Witness.Clean.beam"
    end

    test "une declaration fausse ne rend PAS de plan : elle rougit avant" do
      dir = ebin([@crash, @clean])
      assert_raise Mix.Error, ~r/NON declares/, fn -> CoverOtp27.plan(dir, []) end
    end
  end

  describe "mix.exs — la porte" do
    test "`mix test --cover` passe par cet outil, avec une liste declaree dont chaque module existe" do
      config = Keyword.fetch!(Mix.Project.config(), :test_coverage)
      assert config[:tool] == CoverOtp27

      declared = Keyword.fetch!(config, :otp27_refused)
      assert declared != []

      for mod <- declared do
        assert Code.ensure_loaded?(mod), "#{inspect(mod)} est declare refuse mais n'existe pas"
      end
    end

    test "le seuil est POSE, et il n'est pas le 90 d'Elixir jamais arbitre ici" do
      config = Keyword.fetch!(Mix.Project.config(), :test_coverage)
      threshold = get_in(config, [:summary, :threshold])
      assert is_number(threshold) and threshold > 0
      refute threshold == 90
    end

    test "la porte `test_gate` joue `--cover` : la mesure fait rougir la chaine, pas un rapport a cote" do
      # Le pas est une fonction privee de mix.exs, pas une chaine de l'alias : la seule lecture
      # possible est la source. Ce qu'on epingle est le MOT dans l'appel, pas une prose.
      assert File.read!("mix.exs") =~ ~r/System\.cmd\("mix", \["test", "--cover" \| args\]/
    end
  end
end
