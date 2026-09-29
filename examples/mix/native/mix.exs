defmodule Mix.Tasks.Compile.SampleNative do
  use Mix.Task.Compiler

  def run(_) do
    priv = Path.join(Mix.Project.app_path(), "priv")
    File.mkdir_p!(priv)
    include = Path.join([:code.root_dir(), "erts-#{:erlang.system_info(:version)}", "include"])
    platform = if :os.type() == {:unix, :darwin}, do: ["-undefined", "dynamic_lookup"], else: []

    {output, status} =
      System.cmd(
        System.fetch_env!("CC"),
        ["-shared", "-fPIC", "-I#{include}", "src/sample.c", "-o", Path.join(priv, "sample.so")] ++
          platform ++ OptionParser.split(System.get_env("LDFLAGS", "")),
        stderr_to_stdout: true
      )

    if status != 0, do: Mix.raise(output)
    {:ok, []}
  end
end

defmodule SampleNative.MixProject do
  use Mix.Project

  def project,
    do: [app: :sample_native, version: "0.1.0", compilers: [:sample_native] ++ Mix.compilers()]
end
