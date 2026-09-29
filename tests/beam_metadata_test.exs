Code.require_file("private/beam_metadata.ex")
ExUnit.start()

defmodule BeamMetadataTest do
  use ExUnit.Case

  test "independent builds retain runnable code, documentation and debug information with identical bytes" do
    root = Path.join(System.tmp_dir!(), "beam-metadata-#{System.unique_integer([:positive])}")
    original_options = Code.compiler_options(ignore_module_conflict: true)

    on_exit(fn ->
      Code.compiler_options(original_options)
      :code.purge(MetadataFixture)
      :code.delete(MetadataFixture)
      File.rm_rf!(root)
    end)

    binaries =
      for name <- ["first", "second"] do
        project = Path.join(root, name)
        File.mkdir_p!(Path.join(project, "lib"))
        File.mkdir_p!(Path.join(project, "ebin"))

        File.write!(Path.join(project, "lib/fixture.ex"), """
        defmodule MetadataFixture do
          @moduledoc "Fixture documentation"
          @doc "Return a value without rewriting user strings."
          def answer, do: {42, "/tmp/keep-this-user-value"}
        end
        """)

        File.cd!(project, fn ->
          [{MetadataFixture, compiled}] = Code.compile_file("lib/fixture.ex")
          path = "ebin/Elixir.MetadataFixture.beam"
          File.write!(path, compiled)
          RulesElixir.BeamMetadata.normalize!("ebin")
          normalized = File.read!(path)

          {:module, MetadataFixture} =
            :code.load_binary(MetadataFixture, ~c"fixture.ex", normalized)

          assert MetadataFixture.answer() == {42, "/tmp/keep-this-user-value"}

          assert {:docs_v1, _, :elixir, _, %{"en" => "Fixture documentation"}, _, [_]} =
                   Code.fetch_docs(path)

          assert {:ok, {MetadataFixture, [debug_info: {:debug_info_v1, :elixir_erl, _}]}} =
                   :beam_lib.chunks(normalized, [:debug_info])

          normalized
        end)
      end

    assert Enum.at(binaries, 0) == Enum.at(binaries, 1)
  end
end
