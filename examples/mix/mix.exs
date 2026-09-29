defmodule Sample.MixProject do
  use Mix.Project

  def project do
    [
      app: :sample,
      version: "0.1.0",
      aliases: [compile: [&prepare/1, "compile"]],
      deps: [
        {:sample_native, path: "native"},
        {:sample_dep, path: "dep", runtime: false},
        {:jason, "~> 1.4.4"},
        {:telemetry,
         git: "https://github.com/beam-telemetry/telemetry.git",
         ref: "7baf8085e406d5ae9e43b284d7c866742ae04b28",
         manager: :rebar3,
         only: :test}
      ],
      elixirc_paths:
        if(Mix.env() == :test, do: ["lib", "generated", "support"], else: ["lib", "generated"])
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp prepare(_) do
    if Code.ensure_loaded?(Sample), do: raise("consumer reran the compile alias")
    File.mkdir_p!("priv")
    File.write!("priv/root_alias.txt", "root alias ran")
  end
end
