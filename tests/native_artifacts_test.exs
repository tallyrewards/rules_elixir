Code.require_file("private/native_artifacts.ex")
ExUnit.start()

defmodule NativeArtifactsTest do
  use ExUnit.Case, async: true
  alias RulesElixir.NativeArtifacts

  setup do
    root = Path.join(System.tmp_dir!(), "native-artifacts-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp elf(machine),
    do: <<0x7F, "ELF", 2, 1, 1, 0::size(72), 3::little-16, machine::little-16, 0::size(352)>>

  defp macho(cpu), do: <<0xCF, 0xFA, 0xED, 0xFE, cpu::little-32, 0::size(192)>>

  test "ELF artifacts require the target CPU and OS", %{root: root} do
    File.write!(Path.join(root, "sample.so"), elf(183))
    assert :ok = NativeArtifacts.validate!(root, "aarch64", "linux")

    assert_raise RuntimeError, ~r/expected linux\/x86_64/, fn ->
      NativeArtifacts.validate!(root, "x86_64", "linux")
    end

    assert_raise RuntimeError, ~r/expected macos\/aarch64/, fn ->
      NativeArtifacts.validate!(root, "aarch64", "macos")
    end
  end

  test "Mach-O executables are checked without relying on file extensions", %{root: root} do
    File.write!(Path.join(root, "helper"), macho(0x01000007))
    assert :ok = NativeArtifacts.validate!(root, "x86_64", "macos")

    assert_raise RuntimeError, ~r/expected macos\/aarch64/, fn ->
      NativeArtifacts.validate!(root, "aarch64", "macos")
    end
  end

  test "universal Mach-O includes the requested architecture", %{root: root} do
    table = for cpu <- [0x01000007, 0x0100000C], into: <<>>, do: <<cpu::big-32, 0::size(128)>>

    File.write!(
      Path.join(root, "universal.so"),
      <<0xCA, 0xFE, 0xBA, 0xBE, 2::big-32, table::binary>>
    )

    assert :ok = NativeArtifacts.validate!(root, "aarch64", "macos")
    assert :ok = NativeArtifacts.validate!(root, "x86_64", "macos")
  end

  test "ordinary resources are preserved, including nested and empty files", %{root: root} do
    File.mkdir_p!(Path.join(root, "resources"))
    File.write!(Path.join(root, "resources/data"), "")
    File.write!(Path.join(root, "settings.json"), "{}")

    File.write!(
      Path.join(root, "resources/Example.class"),
      <<0xCA, 0xFE, 0xBA, 0xBE, 0::16, 52::16>>
    )

    assert :ok = NativeArtifacts.validate!(root, "aarch64", "macos")
  end

  test "malformed or unrecognized shared libraries cannot pass as native artifacts", %{root: root} do
    path = Path.join(root, "sample.so")
    File.write!(path, <<0x7F, "ELF">>)

    assert_raise RuntimeError, ~r/malformed native artifact/, fn ->
      NativeArtifacts.validate!(root, "aarch64", "linux")
    end

    File.write!(path, "not a native library")

    assert_raise RuntimeError, ~r/unrecognized native library/, fn ->
      NativeArtifacts.validate!(root, "aarch64", "linux")
    end
  end
end
