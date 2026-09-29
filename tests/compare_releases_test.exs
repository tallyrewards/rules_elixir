ExUnit.start()

defmodule CompareReleasesTest do
  use ExUnit.Case, async: true

  setup do
    root = Path.join(System.tmp_dir!(), "release-compare-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    left = Path.join(root, "left")
    right = Path.join(root, "right")

    for directory <- [left, right] do
      File.mkdir_p!(Path.join(directory, "releases/1.0.0"))
      File.mkdir_p!(Path.join(directory, "lib/sample-1.0.0/ebin"))
      release(directory, :permanent)

      term(Path.join(directory, "lib/sample-1.0.0/ebin/sample.app"), {
        :application,
        :sample,
        [vsn: ~c"1.0.0", modules: [Sample], applications: [:kernel, :stdlib]]
      })

      File.write!(Path.join(directory, "lib/sample-1.0.0/ebin/Elixir.Sample.beam"), "fixture")
    end

    %{left: left, right: right}
  end

  defp term(path, value), do: File.write!(path, :io_lib.format(~c"~p.~n", [value]))

  defp release(directory, mode) do
    term(
      Path.join(directory, "releases/1.0.0/sample.rel"),
      {:release, {~c"sample", ~c"1.0.0"}, {:erts, ~c"17.0"}, [{:sample, ~c"1.0.0", mode}]}
    )
  end

  defp compare(c) do
    System.cmd(
      System.find_executable("elixir"),
      ["tools/compare_releases.exs", c.left, c.right],
      stderr_to_stdout: true
    )
  end

  test "relocated identical release trees agree", c do
    assert {message, 0} = compare(c)
    assert message =~ "OTP release semantics agree"
  end

  test "startup mode and runtime configuration differences fail", c do
    release(c.right, :load)
    File.write!(Path.join(c.right, "releases/1.0.0/runtime.exs"), "import Config\n")
    assert {message, 1} = compare(c)
    assert message =~ "Mismatch: :release"
    assert message =~ "Mismatch: :runtime_config"
  end

  test "a missing BEAM fails even when application descriptors match", c do
    File.rm!(Path.join(c.right, "lib/sample-1.0.0/ebin/Elixir.Sample.beam"))
    assert {message, 1} = compare(c)
    assert message =~ "Mismatch: :sample"
  end
end
