defmodule RulesElixir.NativeArtifacts do
  @moduledoc false
  # Header checks catch wrong CPU/file format; runtime fixtures must verify ABI
  # compatibility and shared-library dependencies.
  @mach_cpus %{0x01000007 => "x86_64", 0x0100000C => "aarch64"}
  @elf_cpus %{62 => "x86_64", 183 => "aarch64"}

  def validate!(directory, cpu, os) do
    for name <- File.ls!(directory) do
      path = Path.join(directory, name)

      if File.dir?(path) do
        validate!(path, cpu, os)
      else
        File.open!(path, [:read, :binary], fn file ->
          header = IO.binread(file, 64)

          case identify(header, file) do
            :other ->
              if Path.extname(path) in [".so", ".dylib", ".dll"],
                do: raise("unrecognized native library: #{path}")

            {format_os, cpus} ->
              unless os == format_os and cpu in cpus,
                do:
                  raise(
                    "native artifact #{path} contains #{format_os}/#{Enum.join(cpus, ",")}, expected #{os}/#{cpu}"
                  )

            :malformed ->
              raise("malformed native artifact: #{path}")
          end
        end)
      end
    end

    :ok
  end

  defp identify(<<0x7F, "ELF", class, endian, version, abi, _::binary>> = bytes, _) do
    if byte_size(bytes) >= 64 and class == 2 and endian in [1, 2] and version == 1 do
      machine = number(binary_part(bytes, 18, 2), endian)
      os = if abi in [0, 3], do: "linux", else: "elf-abi-#{abi}"
      {os, [Map.get(@elf_cpus, machine, "machine-#{machine}")]}
    else
      :malformed
    end
  end

  defp identify(<<magic::binary-size(4), rest::binary>>, _)
       when magic in [<<0xCF, 0xFA, 0xED, 0xFE>>, <<0xFE, 0xED, 0xFA, 0xCF>>] do
    if byte_size(rest) >= 28 do
      endian = if magic == <<0xCF, 0xFA, 0xED, 0xFE>>, do: 1, else: 2
      cpu = number(binary_part(rest, 0, 4), endian)
      {"macos", [Map.get(@mach_cpus, cpu, "cpu-#{cpu}")]}
    else
      :malformed
    end
  end

  defp identify(<<magic::binary-size(4), count::unsigned-big-32, _::binary>>, file)
       when magic in [<<0xCA, 0xFE, 0xBA, 0xBE>>, <<0xCA, 0xFE, 0xBA, 0xBF>>] do
    entry_size = if magic == <<0xCA, 0xFE, 0xBA, 0xBE>>, do: 20, else: 32

    # Both formats carry an architecture table followed by their Mach-O slices.
    # Bound the table before reading untrusted package bytes.
    if count > 0 and count <= 32 do
      case :file.pread(file, 8, count * entry_size) do
        {:ok, table} when byte_size(table) == count * entry_size ->
          cpus =
            for index <- 0..(count - 1) do
              cpu = number(binary_part(table, index * entry_size, 4), 2)
              Map.get(@mach_cpus, cpu, "cpu-#{cpu}")
            end

          {"macos", cpus}

        _ ->
          :malformed
      end
    else
      # Java class files share this magic but encode a version, not a slice count.
      :other
    end
  end

  defp identify(<<magic::binary-size(4), _::binary>>, _)
       when magic in [<<0x7F, "ELF">>, <<0xCA, 0xFE, 0xBA, 0xBE>>, <<0xCA, 0xFE, 0xBA, 0xBF>>],
       do: :malformed

  defp identify(_, _), do: :other
  defp number(bytes, 1), do: :binary.decode_unsigned(bytes, :little)
  defp number(bytes, 2), do: :binary.decode_unsigned(bytes, :big)
end
