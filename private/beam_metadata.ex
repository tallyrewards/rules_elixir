defmodule RulesElixir.BeamMetadata do
  @moduledoc false

  # Elixir's deterministic compiler option leaves absolute source paths in
  # debug information and documentation. Use its own relative source name in
  # those metadata fields; never rewrite instructions or user literal values.
  def normalize!(directory) do
    for path <- Path.wildcard(Path.join(directory, "*.beam")) do
      {:ok, _, chunks} = :beam_lib.all_chunks(String.to_charlist(path))

      case List.keyfind(chunks, ~c"Dbgi", 0) do
        {_, bytes} ->
          case :erlang.binary_to_term(bytes) do
            {:debug_info_v1, :elixir_erl, {:elixir_v1, %{relative_file: relative} = info, specs}} ->
              debug = {:debug_info_v1, :elixir_erl, {:elixir_v1, %{info | file: relative}, specs}}

              rewritten =
                Enum.map(chunks, fn
                  {~c"Dbgi", _} -> {~c"Dbgi", encode(debug)}
                  {~c"Docs", docs} -> {~c"Docs", normalize_docs(docs, relative)}
                  chunk -> chunk
                end)

              {:ok, beam} = :beam_lib.build_module(rewritten)
              File.write!(path, beam)

            _ ->
              :ok
          end

        nil ->
          :ok
      end
    end
  end

  defp normalize_docs(bytes, relative) do
    case :erlang.binary_to_term(bytes) do
      {:docs_v1, line, language, format, doc, %{source_path: _} = metadata, entries} ->
        encode(
          {:docs_v1, line, language, format, doc,
           %{metadata | source_path: String.to_charlist(relative)}, entries}
        )

      _ ->
        bytes
    end
  end

  defp encode(term), do: :erlang.term_to_binary(term, [:compressed, :deterministic])
end
