defmodule Sample.MixProject do
  use Mix.Project

  def project do
    [
      app: :sample,
      version: "0.1.0",
      aliases: [compile: [&prepare/1, "compile"]],
      deps: [
        {:sample_dep, path: "dep", runtime: false}
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
