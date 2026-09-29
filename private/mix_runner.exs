defmodule RulesElixir.MixRunner do
  def main([config_path, work | extra_args]) do
    config = JSON.decode!(File.read!(config_path))
    execroot = File.cwd!()
    work = File.cd!(work, &File.cwd!/0)
    project = Path.join(work, "project")
    File.mkdir_p!(project)

    for %{"source" => source, "destination" => destination} <- config["sources"] do
      stage(Path.expand(source, execroot), Path.join(project, destination))
    end

    project = Path.join(project, config["project_dir"] || "")

    System.put_env("HOME", Path.join(work, "home"))
    System.put_env("MIX_HOME", Path.join(work, "home/mix"))
    System.put_env("HEX_HOME", Path.join(work, "home/hex"))
    System.put_env("HEX_OFFLINE", "1")
    System.put_env("MIX_ENV", config["root_environment"] || config["environment"])
    System.put_env("ERL_COMPILER_OPTIONS", "deterministic")

    File.mkdir_p!(System.get_env("MIX_HOME"))
    Mix.start()
    Mix.env(String.to_atom(config["environment"]))

    for archive <- config["archives"] do
      Mix.Tasks.Archive.Install.run(["--force", Path.expand(archive, execroot)])
    end

    Mix.Local.append_archives()

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

            if config_path = config["compile_config"] do
              old_env = Mix.env()
              Mix.env(String.to_atom(config["config_environment"]))

              try do
                Mix.Tasks.Loadconfig.run([Path.expand(config_path, execroot)])
              after
                Mix.env(old_env)
              end
            else
              unless config["is_dependency"], do: Mix.Tasks.Loadconfig.run([])
            end

            case config["operation"] do
              "compile" ->
                args = ["--no-deps-check", "--no-deps-compile", "--no-prune-code-paths"]

                # Aliases may generate resources. They run only in this compile
                # action; tests and releases call their assembly-only tasks directly.
                case Mix.Task.run("compile", args) do
                  {:error, diagnostics} ->
                    raise("Mix compilation failed: #{inspect(diagnostics)}")

                  _ ->
                    :ok
                end

                export_app(config, Mix.Project.app_path(), execroot)
            end
          end
        )
      end
    end)
  end

  defp export_app(config, app_path, execroot) do
    unless File.regular?(Path.join([app_path, "ebin", config["app"] <> ".app"])),
      do: raise("compiler did not produce #{config["app"]}.app")

    for kind <- ~w(ebin priv include consolidated) do
      output = Path.expand(config["outputs"][kind], execroot)
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

  defp stage(source, target) do
    if File.dir?(source) do
      File.mkdir_p!(target)
      copy_contents(source, target)
    else
      File.mkdir_p!(Path.dirname(target))
      File.cp!(source, target)
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
