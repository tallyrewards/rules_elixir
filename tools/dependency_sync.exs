defmodule RulesElixir.DependencySync do
  @moduledoc """
  Offline Mix semantic analysis. Fetch dependencies explicitly with Mix first.
  Each environment runs in a fresh VM: project modules and Mix caches must not
  leak between evaluations. This tool never compiles or fetches dependencies.
  """
  @environments ~w(dev test prod)

  def main(args) do
    {opts, [], []} =
      OptionParser.parse(args,
        strict: [
          project: :string,
          output: :string,
          check: :boolean,
          environment: :string,
          input: :keep
        ]
      )

    project = File.cd!(Keyword.get(opts, :project, "."), &File.cwd!/0)

    if environment = opts[:environment] do
      unless environment in @environments, do: raise("unsupported environment #{environment}")

      result =
        analyse(
          project,
          String.to_existing_atom(environment),
          Keyword.get_values(opts, :input)
        )

      File.write!(Keyword.fetch!(opts, :output), encode(result) <> "\n")
    else
      output = Path.expand(Keyword.get(opts, :output, "rules_elixir.lock.json"))

      work =
        Path.join(
          System.tmp_dir!(),
          "rules-elixir-sync-#{System.pid()}-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(work)

      try do
        snapshots =
          for environment <- @environments, into: %{} do
            fragment = Path.join(work, environment <> ".json")
            inputs = Enum.flat_map(Keyword.get_values(opts, :input), &["--input", &1])

            {log, status} =
              System.cmd(
                System.find_executable("elixir"),
                [
                  __ENV__.file,
                  "--project",
                  project,
                  "--environment",
                  environment,
                  "--output",
                  fragment
                ] ++ inputs,
                stderr_to_stdout: true
              )

            if status != 0, do: raise("Mix analysis failed for #{environment}:\n#{log}")
            {environment, JSON.decode!(File.read!(fragment))}
          end

        manifest = encode(%{"schema_version" => 1, "environments" => snapshots}) <> "\n"

        if opts[:check] do
          unless File.read!(output) == manifest do
            diagnostic =
              if directory = System.get_env("TEST_UNDECLARED_OUTPUTS_DIR") do
                File.mkdir_p!(directory)
                path = Path.join(directory, "actual-rules_elixir.lock.json")
                File.write!(path, manifest)
                "; regenerated manifest retained at #{path}"
              else
                ""
              end

            raise("dependency manifest drift: regenerate #{output}#{diagnostic}")
          end
        else
          File.write!(output, manifest)
        end
      after
        File.rm_rf!(work)
      end
    end
  end

  def analyse(project, environment, extra_inputs \\ []) do
    System.put_env("MIX_ENV", to_string(environment))
    Mix.start()
    Mix.Local.append_archives()
    Mix.env(environment)
    System.put_env("HEX_OFFLINE", "1")

    Mix.Project.in_project(:rules_elixir_analysis, project, fn _ ->
      if Mix.Project.umbrella?(),
        do: raise("umbrella roots are not supported; analyse each application root")

      config = Mix.Project.config()
      # Analysis runs with configuration loaded, as Mix does. Configuration is
      # not part of the manifest's identity: a change that alters the graph
      # changes the analysed packages, and compile actions depend on the
      # configuration they read, not on this manifest.
      Mix.Tasks.Loadconfig.run([])

      for input <- extra_inputs,
          not File.regular?(input),
          do: raise("missing analysis input #{input}")

      deps = Mix.Dep.load_and_cache()
      lock = Mix.Dep.Lock.read()

      for dep <- deps do
        if Mix.Dep.diverged?(dep) or not Mix.Dep.available?(dep),
          do: raise("#{dep.app}: #{Mix.Dep.format_status(dep)}; run mix deps.get explicitly")

        if dep.system_env != [],
          do: raise("#{dep.app}: system_env dependencies need an explicit build capability")

        if Keyword.has_key?(dep.opts, :compile),
          do: raise("#{dep.app}: custom compile options require an explicit build adapter")

        if dep.opts[:app] == false,
          do: raise("#{dep.app}: non-OTP dependencies require an explicit build adapter")
      end

      selected = Map.new(deps, &{&1.app, &1})

      packages =
        for dep <- deps, into: %{} do
          source = source(dep, lock, project)

          {characteristics, declarations} =
            if dep.manager == :mix do
              Mix.Dep.in_dependency(dep, fn _ ->
                config = Mix.Project.config()
                {characteristics(config), declarations(config)}
              end)
            else
              {%{}, Map.new(dep.deps, &{&1.app, &1.opts})}
            end

          edges = edges(dep.deps, declarations, selected, dep.opts[:env] || :prod)

          {Atom.to_string(dep.app),
           %{
             "source" => source,
             "manager" => to_string(dep.manager),
             "environment" => to_string(dep.opts[:env] || :prod),
             "project" => characteristics,
             "dependencies" => edges
           }}
        end

      root_deps = Enum.filter(deps, & &1.top_level)

      %{
        "root" =>
          Map.merge(characteristics(config), %{
            "app" => to_string(Keyword.fetch!(config, :app)),
            "dependencies" => edges(root_deps, declarations(config), selected, environment)
          }),
        "packages" => packages,
        "inputs" =>
          fingerprints(["mix.exs", config[:lockfile] || "mix.lock"] ++ extra_inputs)
      }
    end)
  end

  defp characteristics(config) do
    %{
      "version" => config[:version],
      "elixirc_paths" => config[:elixirc_paths] || ["lib"],
      "compilers" => Enum.map(config[:compilers] || Mix.compilers(), &to_string/1),
      "consolidate_protocols" => Keyword.get(config, :consolidate_protocols, true)
    }
  end

  defp declarations(config) do
    Map.new(config[:deps] || [], fn
      {app, opts} when is_list(opts) -> {app, opts}
      {app, _requirement} -> {app, []}
      {app, _requirement, opts} -> {app, opts}
    end)
  end

  defp edges(deps, declarations, selected, environment) do
    deps
    |> Enum.filter(fn dep ->
      opts = Map.get(declarations, dep.app, dep.opts)
      Map.has_key?(selected, dep.app) and environment in List.wrap(opts[:only] || environment)
    end)
    |> Enum.map(fn dep ->
      opts = Map.get(declarations, dep.app, dep.opts)
      chosen = Map.fetch!(selected, dep.app)

      %{
        "app" => to_string(dep.app),
        "compile" => true,
        "runtime" => Keyword.get(opts, :runtime, true),
        "optional" => Keyword.get(opts, :optional, false),
        "override" => Keyword.get(chosen.opts, :override, false),
        "environment" => to_string(chosen.opts[:env] || :prod)
      }
    end)
    |> Enum.sort_by(& &1["app"])
  end

  defp source(dep, lock, project) do
    cond do
      dep.scm == Mix.SCM.Path ->
        %{"type" => "path", "path" => Path.relative_to(dep.opts[:dest], project)}

      true ->
        case Map.fetch!(lock, dep.app) do
          {:hex, package, version, inner, managers, _, repository, outer} when is_binary(outer) ->
            %{
              "type" => "hex",
              "package" => to_string(package),
              "version" => version,
              "sha256" => outer,
              "inner_sha256" => inner,
              "repository" => repository,
              "build_tools" => Enum.map(managers, &to_string/1)
            }

          {:git, url, revision, options} ->
            if options[:subdir],
              do: raise("#{dep.app}: Git subdir dependencies need an explicit source adapter")

            %{
              "type" => "git",
              "url" => url,
              "revision" => revision,
              "submodules" => Keyword.get(options, :submodules, false),
              "sparse" => options[:sparse]
            }

          other ->
            raise("#{dep.app}: unsupported or non-immutable lock entry #{inspect(other)}")
        end
    end
  end

  defp fingerprints(paths) do
    for path <- Enum.sort(Enum.uniq(paths)), File.regular?(path), into: %{} do
      {path, :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)}
    end
  end

  # JSON.encode!/1 does not promise map ordering. Sort recursively at the
  # serialization boundary so output is stable across VMs and map sizes.
  def encode(value), do: encode(value, 0)
  defp encode(value, _depth) when value == %{}, do: "{}"

  defp encode(value, depth) when is_map(value) do
    padding = String.duplicate("  ", depth + 1)

    "{\n" <>
      (value
       |> Enum.sort_by(&elem(&1, 0))
       |> Enum.map_join(",\n", fn {k, v} ->
         padding <> JSON.encode!(k) <> ": " <> encode(v, depth + 1)
       end)) <> "\n" <> String.duplicate("  ", depth) <> "}"
  end

  defp encode([], _depth), do: "[]"

  defp encode(value, depth) when is_list(value) do
    padding = String.duplicate("  ", depth + 1)

    "[\n" <>
      Enum.map_join(value, ",\n", &(padding <> encode(&1, depth + 1))) <>
      "\n" <> String.duplicate("  ", depth) <> "]"
  end

  defp encode(value, _depth), do: JSON.encode!(value)
end

RulesElixir.DependencySync.main(System.argv())
