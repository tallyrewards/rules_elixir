defmodule RulesElixir.CompareReleases do
  @moduledoc """
  Compare OTP semantics rather than compiler paths, native bytes or launcher wrappers.
  Usage: elixir compare_releases.exs LEFT_RELEASE RIGHT_RELEASE
  """
  @fields ~w(vsn applications included_applications optional_applications registered mod modules)a

  def main([left, right]) do
    a = describe(left)
    b = describe(right)

    differences =
      for key <- Enum.uniq(Map.keys(a) ++ Map.keys(b)),
          a[key] != b[key],
          do: {key, a[key], b[key]}

    if differences == [] do
      IO.puts("OTP release semantics agree (#{map_size(a) - 2} applications)")
    else
      for {key, x, y} <- differences do
        IO.puts("Mismatch: #{inspect(key)}")
        IO.puts("  left:  #{inspect(x, limit: :infinity)}")
        IO.puts("  right: #{inspect(y, limit: :infinity)}")
      end

      System.halt(1)
    end
  end

  defp describe(root) do
    descriptor =
      case Path.wildcard(Path.join(root, "releases/*/*.rel")) do
        [path] ->
          path

        _ ->
          raise(
            "expected one releases/VERSION/*.rel under #{root}; pass the release tree, not a launcher-only wrapper package"
          )
      end

    {:ok, [{:release, identity, erts, apps}]} = :file.consult(String.to_charlist(descriptor))
    runtime = Path.join(Path.dirname(descriptor), "runtime.exs")
    runtime = if File.regular?(runtime), do: File.read!(runtime), else: nil

    metadata =
      for path <- Path.wildcard(Path.join(root, "lib/*/ebin/*.app")), into: %{} do
        {:ok, [{:application, app, values}]} = :file.consult(String.to_charlist(path))

        fields =
          for key <- @fields, into: %{} do
            value = values[key]
            value = if is_list(value) and key != :vsn, do: Enum.sort(value), else: value
            {key, value}
          end

        beams =
          path
          |> Path.dirname()
          |> Path.join("*.beam")
          |> Path.wildcard()
          |> Enum.map(&Path.basename/1)
          |> Enum.sort()

        {app, Map.put(fields, :beam_files, beams)}
      end

    Map.merge(metadata, %{release: {identity, erts, Enum.sort(apps)}, runtime_config: runtime})
  end
end

RulesElixir.CompareReleases.main(System.argv())
