defmodule RulesElixir.MixRunner do
  def main([config_path, work | extra_args]) do
    config = JSON.decode!(File.read!(config_path))
    execroot = File.cwd!()
    work = File.cd!(work, &File.cwd!/0)
    project = Path.join(work, "project")
    File.mkdir_p!(project)

    staged =
      Enum.flat_map(config["sources"], fn %{"source" => source, "destination" => destination} ->
        stage(Path.expand(source, execroot), Path.join(project, destination))
      end)

    inventory = Path.join(work, "staged.etf")

    previous =
      if File.exists?(inventory),
        do: :erlang.binary_to_term(File.read!(inventory), [:safe]),
        else: []

    for removed <- previous -- staged, do: File.rm!(removed)
    File.write!(inventory, :erlang.term_to_binary(staged))

    project = Path.join(project, config["project_dir"] || "")

    System.put_env("HOME", Path.join(work, "home"))
    System.put_env("MIX_HOME", Path.join(work, "home/mix"))
    System.put_env("HEX_HOME", Path.join(work, "home/hex"))
    System.put_env("HEX_OFFLINE", "1")
    System.put_env("MIX_ENV", config["root_environment"] || config["environment"])
    System.put_env("ERL_COMPILER_OPTIONS", "deterministic")

    if config["operation"] == "test" do
      total = String.to_integer(System.get_env("TEST_TOTAL_SHARDS", "1"))
      index = String.to_integer(System.get_env("TEST_SHARD_INDEX", "0"))

      # Project configuration may derive database/resource names from this value.
      # Set it before Mix evaluates the project or loads its configuration.
      if total > 1 or System.get_env("MIX_TEST_PARTITION") == nil do
        System.put_env("MIX_TEST_PARTITION", to_string(index + 1))
      end
    end

    File.mkdir_p!(System.get_env("MIX_HOME"))
    Mix.start()
    Mix.env(String.to_atom(config["environment"]))

    for archive <- config["archives"] do
      Mix.Tasks.Archive.Install.run(["--force", Path.expand(archive, execroot)])
    end

    Mix.Local.append_archives()

    if config["operation"] == "config" do
      evaluate_config(
        Path.expand(config["entrypoint"], execroot),
        Path.expand(config["output"], execroot)
      )

      System.halt(0)
    end

    if config["operation"] in ["compile", "rebar3"] and config["native"] != %{} do
      native = config["native"]
      tool_dir = Path.join(work, "bin")
      File.mkdir_p!(tool_dir)

      for {name, source} <- native["tools"] do
        # Execute the original path so tools can locate their adjacent Bazel
        # runfiles. A symlink through tool_dir changes $0 for shell tools.
        wrapper = Path.join(tool_dir, name)

        File.write!(
          wrapper,
          "#!/bin/sh\nexec " <> shell_quote(Path.expand(source, execroot)) <> " \"$@\"\n"
        )

        File.chmod!(wrapper, 0o755)
      end

      for {name, [compiler | flags]} <- native["commands"] do
        wrapper = Path.join(tool_dir, String.downcase(name))
        args = [Path.expand(compiler, execroot) | Enum.map(flags, &absolute_flag(&1, execroot))]

        includes =
          for {flag, paths} <- native["includes"],
              path <- paths,
              do: flag <> Path.expand(path, execroot)

        args = args ++ includes ++ Enum.map(native["defines"], &("-D" <> &1))

        File.write!(
          wrapper,
          "#!/bin/sh\nexec " <> Enum.map_join(args, " ", &shell_quote/1) <> " \"$@\"\n"
        )

        File.chmod!(wrapper, 0o755)
        System.put_env(name, wrapper)
      end

      for {name, value} <- native["environment"],
          do: System.put_env(name, absolute_flag(value, execroot))

      System.put_env(
        "LDFLAGS",
        Enum.map_join(native["link_flags"], " ", &shell_quote(absolute_flag(&1, execroot))) <>
          " " <> Enum.map_join(native["libraries"], " ", &shell_quote(Path.expand(&1, execroot)))
      )

      System.put_env("PATH", tool_dir <> ":" <> System.fetch_env!("PATH"))

      if Map.has_key?(native["tools"], "make"),
        do: System.put_env("MAKE", Path.join(tool_dir, "make"))
    end

    if config["operation"] == "sync" do
      inputs = Enum.flat_map(config["inputs"], &["--input", &1])

      {_, status} =
        System.cmd(
          System.find_executable("elixir"),
          [
            Path.expand(config["sync"], execroot),
            "--project",
            project,
            "--output",
            Path.expand(config["manifest"], execroot),
            "--check",
            "--bazel-sources"
          ] ++ inputs,
          into: IO.stream()
        )

      System.halt(status)
    end

    build = Path.join(work, "build")
    System.put_env("MIX_BUILD_PATH", build)
    lib = Path.join(build, "lib")
    File.mkdir_p!(lib)

    for dep <- config["dependencies"] do
      destination = Path.join(lib, dep["app"])
      File.rm_rf!(destination)
      File.mkdir_p!(destination)

      for {kind, paths} <- dep["files"], source <- paths do
        source = Path.expand(source, execroot)

        target =
          if File.dir?(source),
            do: Path.join(destination, kind),
            else: Path.join([destination, kind, Path.basename(source)])

        File.mkdir_p!(Path.dirname(target))
        File.ln_s!(source, target)
      end

      Code.prepend_path(Path.join(destination, "ebin"))
    end

    File.cd!(project, fn ->
      if config["operation"] == "rebar3" do
        app_path = Path.join(lib, config["app"])
        File.mkdir_p!(app_path)

        for dir <- ~w(include priv src ebin), File.dir?(dir) do
          File.ln_s!(Path.expand(dir), Path.join(app_path, dir))
        end

        rebar_config =
          Mix.Rebar.load_config(".") |> Mix.Rebar.dependency_config() |> offline_rebar_config()

        rebar_config_path = Path.join(work, "rebar.config")
        File.write!(rebar_config_path, Mix.Rebar.serialize_config(rebar_config))

        {_, status} =
          System.cmd(
            System.find_executable("escript"),
            [
              Path.expand(config["rebar3"], execroot),
              "bare",
              "compile",
              "--paths",
              Path.join(lib, "*/ebin")
            ],
            into: IO.stream(),
            env: [
              {"REBAR_BARE_COMPILER_OUTPUT_DIR", app_path},
              {"REBAR_SKIP_PROJECT_PLUGINS", "true"},
              {"REBAR_CONFIG", rebar_config_path},
              {"REBAR_PROFILE", "prod"},
              {"REBAR_OFFLINE", "true"},
              {"TERM", "dumb"}
            ]
          )

        if status != 0, do: raise("Rebar compilation failed for #{config["app"]}")
        export_app(config, app_path, execroot)
      else
        post_config = [build_path: build, prune_code_paths: false]

        post_config =
          if config["is_dependency"],
            do: Keyword.put(post_config, :consolidate_protocols, false),
            else: post_config

        Mix.Project.in_project(
          String.to_atom(config["app"]),
          ".",
          post_config,
          fn _ ->
            unless to_string(Mix.Project.config()[:app]) == config["app"],
              do: raise("Bazel app_name differs from Mix project application")

            cond do
              projection = config["projection"] ->
                load_projection(Path.expand(projection, execroot))

              config["is_dependency"] ->
                :ok

              true ->
                Mix.Tasks.Loadconfig.run([])
            end

            if config["operation"] in ["test", "release"] do
              # Mix dispatches aliases before the task can honor --no-compile.
              # Compilation may reenable itself, so task completion markers are
              # insufficient. Remove only this alias from the consumer's config;
              # keep custom release-step aliases available. This Mix adapter is
              # covered by the supported-version integration fixtures.
              aliases = Keyword.delete(Mix.Project.config()[:aliases] || [], :compile)
              Mix.ProjectStack.merge_config(aliases: aliases)
            end

            case config["operation"] do
              "compile" ->
                args = ["--no-deps-check", "--no-deps-compile", "--no-prune-code-paths"]

                # Aliases may generate resources. They run only in this compile
                # action; tests and releases call their assembly-only tasks directly.
                compile = fn ->
                  case Mix.Task.run("compile", args) do
                    {:error, diagnostics} ->
                      raise("Mix compilation failed: #{inspect(diagnostics)}")

                    _ ->
                      :ok
                  end

                  export_app(config, Mix.Project.app_path(), execroot)
                end

                if reads = config["reads"] do
                  record_config_reads(Path.expand(reads, execroot), fn ->
                    compile_or_record_failure(config, execroot, compile)
                  end)
                else
                  compile.()
                end

              "release" ->
                Mix.Tasks.Release.run([
                  config["release"],
                  "--no-compile",
                  "--no-deps-check",
                  "--overwrite",
                  "--path",
                  Path.expand(config["output"], execroot)
                ])

              "test" ->
                total = String.to_integer(System.get_env("TEST_TOTAL_SHARDS", "1"))
                if path = System.get_env("TEST_SHARD_STATUS_FILE"), do: File.write!(path, "")
                args = ["--no-compile", "--no-deps-check"] ++ config["args"] ++ extra_args
                args = if total > 1, do: args ++ ["--partitions", to_string(total)], else: args
                Mix.Tasks.Test.run(args)
            end
          end
        )
      end
    end)
  end

  # One line per application key: app, key and the value's external term
  # format. Sorted, so an unchanged configuration produces identical bytes.
  defp evaluate_config(entrypoint, output) do
    {entries, _imports} =
      Config.Reader.read_imports!(entrypoint, env: Mix.env(), target: Mix.target())

    lines =
      for {app, values} <- entries, {key, value} <- values do
        encoded = value |> :erlang.term_to_binary([:deterministic]) |> Base.encode64()
        Enum.join([config_name(app), config_name(key), encoded], "\t") <> "\n"
      end

    File.write!(output, lines |> Enum.sort() |> Enum.join())
  end

  defp config_name(atom) do
    name = Atom.to_string(atom)

    if String.contains?(name, ["\t", "\n"]),
      do: raise("configuration names cannot contain tabs or newlines: #{inspect(atom)}")

    name
  end

  defp load_projection(path) do
    for line <- String.split(File.read!(path), "\n", trim: true) do
      [app, key, value] = String.split(line, "\t")
      value = value |> Base.decode64!() |> :erlang.binary_to_term()
      Application.put_env(String.to_atom(app), String.to_atom(key), value, persistent: true)
    end
  end

  # Every application environment lookup goes through these functions,
  # including Application.compile_env and reads the compiler does not track.
  @config_reads [
    {:application, :get_env, 2},
    {:application, :get_env, 3},
    {:application, :get_all_env, 1}
  ]

  defp record_config_reads(path, fun) do
    tracer = spawn_link(fn -> collect_config_reads(MapSet.new()) end)
    for mfa <- @config_reads, do: :erlang.trace_pattern(mfa, true, [:global])
    :erlang.trace(:all, true, [:call, {:tracer, tracer}])

    try do
      fun.()
    after
      :erlang.trace(:all, false, [:call])
      for mfa <- @config_reads, do: :erlang.trace_pattern(mfa, false, [:global])
      delivered = :erlang.trace_delivered(:all)

      receive do
        {:trace_delivered, :all, ^delivered} -> :ok
      end

      send(tracer, {:done, self()})

      reads =
        receive do
          {:config_reads, ^tracer, reads} -> reads
        end

      lines =
        for {app, key} <- reads do
          config_name(app) <> "\t" <> if(key, do: config_name(key), else: "") <> "\n"
        end

      File.write!(path, lines |> Enum.sort() |> Enum.join())
    end
  end

  defp collect_config_reads(reads) do
    receive do
      {:trace, _, :call, {:application, :get_env, [app, key | _]}}
      when is_atom(app) and is_atom(key) ->
        collect_config_reads(MapSet.put(reads, {app, key}))

      {:trace, _, :call, {:application, :get_all_env, [app]}} when is_atom(app) ->
        collect_config_reads(MapSet.put(reads, {app, nil}))

      {:done, from} ->
        send(from, {:config_reads, self(), reads})

      _ ->
        collect_config_reads(reads)
    end
  end

  # The unconfigured compilation may fail, for example on compile_env!/2.
  # Its reads still select the configuration for the compilation that counts.
  defp compile_or_record_failure(config, execroot, compile) do
    status = config["status"] && Path.expand(config["status"], execroot)

    try do
      compile.()
      if status, do: File.write!(status, "ok")
    catch
      kind, reason ->
        unless status, do: :erlang.raise(kind, reason, __STACKTRACE__)
        for {_, output} <- config["outputs"], do: File.mkdir_p!(Path.expand(output, execroot))
        File.write!(status, "failed")
    end
  end

  defp export_app(config, app_path, execroot) do
    unless File.regular?(Path.join([app_path, "ebin", config["app"] <> ".app"])),
      do: raise("compiler did not produce #{config["app"]}.app")

    for kind <- ~w(ebin priv include consolidated) do
      output = Path.expand(config["outputs"][kind], execroot)
      File.rm_rf!(output)
      File.mkdir_p!(output)
      source = Path.join(app_path, kind)
      source = if not File.dir?(source) and kind in ~w(priv include), do: kind, else: source
      if File.dir?(source), do: copy_contents(source, output)
    end

    Code.require_file(Path.expand(config["beam_metadata"], execroot))

    for kind <- ~w(ebin consolidated) do
      apply(RulesElixir.BeamMetadata, :normalize!, [
        Path.expand(config["outputs"][kind], execroot)
      ])
    end

    Code.require_file(Path.expand(config["native_validator"], execroot))

    apply(RulesElixir.NativeArtifacts, :validate!, [
      Path.expand(config["outputs"]["priv"], execroot),
      config["target_platform"]["cpu"],
      config["target_platform"]["os"]
    ])
  end

  defp offline_rebar_config(config) do
    if config[:plugins] not in [nil, []] and config[:provider_hooks] not in [nil, []],
      do: raise("Rebar plugin provider hooks require an explicit declared build adapter")

    # Bare compilation does not need documentation/formatting plugins. Rebar
    # otherwise tries to fetch them even with REBAR_OFFLINE and project plugins
    # disabled. Keep only the profile Mix actually uses, and reject hooked plugins.
    config
    |> Keyword.delete(:plugins)
    |> Keyword.delete(:project_plugins)
    |> Keyword.update(:profiles, [], fn profiles ->
      for {:prod, values} <- profiles, do: {:prod, offline_rebar_config(values)}
    end)
  end

  # Make execroot-relative paths absolute where a path begins: at the start of
  # the flag, after "=", "," or ":", or after a one-letter option such as -I.
  # A bazel-out path to an external repository contains "external/" too; that
  # occurrence is part of the same path and must not be rewritten again.
  defp absolute_flag(flag, execroot) do
    Regex.replace(~r{(^|[=,:]|^-[A-Za-z])(external/|bazel-out/)}, flag, "\\1#{execroot}/\\2")
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"

  # Preserve unchanged source timestamps for Mix's incremental compiler. The
  # input inventory above also removes sources deleted since the last request.
  defp stage(source, target) do
    if File.dir?(source) do
      File.mkdir_p!(target)
      Enum.flat_map(File.ls!(source), &stage(Path.join(source, &1), Path.join(target, &1)))
    else
      File.mkdir_p!(Path.dirname(target))

      unless File.regular?(target) and File.read!(source) == File.read!(target),
        do: File.cp!(source, target)

      [target]
    end
  end

  # Mix often symlinks priv to its source. Outputs must contain bytes, not
  # links back into an action's temporary directory or another output tree.
  defp copy_contents(source, output) do
    for name <- File.ls!(source) do
      src = Path.join(source, name)
      dst = Path.join(output, name)

      if File.dir?(src) do
        File.mkdir_p!(dst)
        copy_contents(src, dst)
      else
        File.cp!(src, dst)
      end
    end
  end
end

RulesElixir.MixRunner.main(System.argv())
