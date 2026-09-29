defmodule RulesElixir.MixWorker do
  def main([runner | args]) do
    # Bazel starts a sandboxed worker in a directory it owns for that worker
    # (bazel-workers/worker-N-<mnemonic>/<workspace>), and an unsandboxed one in
    # the execroot. Keep the state beside that directory, inside the output
    # base, so it never lands in a shared temporary directory and bazel clean
    # removes whatever an interrupted worker left behind.
    work = Path.join(Path.dirname(File.cwd!()), "rules_elixir-mix-state-#{System.pid()}")

    File.mkdir_p!(work)

    try do
      if args == ["--persistent_worker"] do
        loop(runner, work, nil)
      else
        [config] = expand(args)
        {output, status} = compile(runner, config, work)
        IO.write(output)
        if status != 0, do: System.halt(status)
      end
    after
      File.rm_rf!(work)
    end
  end

  defp loop(runner, work, previous) do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      line ->
        request = JSON.decode!(line)
        {response, signature} = respond(request, runner, work, previous)
        IO.puts(JSON.encode!(Map.put(response, "requestId", request["requestId"] || 0)))
        loop(runner, work, signature)
    end
  end

  defp respond(request, runner, work, previous) do
    try do
      [config_path] = expand(request["arguments"])
      config = JSON.decode!(File.read!(config_path))
      # Only declared, ordinary Elixir source files can change incrementally.
      # All other inputs, including dependency trees and generated sources,
      # form the identity of this compiler state.
      incremental_sources =
        for source <- config["sources"],
            Path.extname(source["source"]) == ".ex" and File.regular?(source["source"]),
            into: MapSet.new(),
            do: source["source"]

      declared =
        Enum.reject(
          request["inputs"],
          &(&1["path"] == config_path or MapSet.member?(incremental_sources, &1["path"]))
        )

      # An absent digest must never authorize reuse. Hash the declared input
      # ourselves when the worker implementation omits it, and report how often
      # that happens: hashing a dependency tree here costs compilation time.
      unhashed = Enum.count(declared, &(nonempty(&1["digest"]) == nil))

      inputs =
        declared
        |> Enum.map(&{&1["path"], nonempty(&1["digest"]) || digest(&1["path"])})
        |> Enum.sort()

      stable_sources =
        Enum.reject(config["sources"], &MapSet.member?(incremental_sources, &1["source"]))

      signature =
        :crypto.hash(
          :sha256,
          :erlang.term_to_binary({Map.put(config, "sources", stable_sources), inputs})
        )

      if signature != previous, do: File.rm_rf!(work)
      File.mkdir_p!(work)
      {output, status} = compile(runner, config_path, work)
      reuse = if signature == previous, do: "reused", else: "reset"

      if status != 0, do: File.rm_rf!(work)

      summary = "Mix compiler state: #{reuse} (#{unhashed} inputs hashed by the worker)\n"

      {%{"exitCode" => status, "output" => summary <> output},
       if(status == 0, do: signature, else: nil)}
    rescue
      error ->
        File.rm_rf!(work)
        {%{"exitCode" => 1, "output" => Exception.format(:error, error, __STACKTRACE__)}, nil}
    end
  end

  defp nonempty(value) when value in [nil, ""], do: nil
  defp nonempty(value), do: value

  defp digest(path) do
    if File.dir?(path) do
      path |> File.ls!() |> Enum.sort() |> Enum.map(&{&1, digest(Path.join(path, &1))})
    else
      :crypto.hash(:sha256, File.read!(path))
    end
  end

  defp compile(runner, config, work) do
    System.cmd(System.find_executable("elixir"), [runner, config, work], stderr_to_stdout: true)
  end

  defp expand(args) do
    Enum.flat_map(args, fn
      "@" <> path -> path |> File.read!() |> String.split("\n", trim: true) |> expand()
      arg -> [arg]
    end)
  end
end

RulesElixir.MixWorker.main(System.argv())
