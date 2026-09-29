ExUnit.start(max_cases: 2)

defmodule DependencySyncTest do
  use ExUnit.Case, async: true

  setup do
    root = Path.join(System.tmp_dir!(), "sync-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, script: Path.expand("tools/dependency_sync.exs")}
  end

  defp project(root, app, dependencies) do
    File.mkdir_p!(root)

    File.write!(Path.join(root, "mix.exs"), """
    defmodule #{Macro.camelize(to_string(app))}.MixProject do
      use Mix.Project
      def project, do: [app: :#{app}, version: "0.1.0", deps: #{dependencies}]
    end
    """)
  end

  defp sync(context, args \\ []) do
    System.cmd(
      System.find_executable("elixir"),
      [
        context.script,
        "--project",
        context.root,
        "--output",
        Path.join(context.root, "lock.json")
      ] ++ args,
      stderr_to_stdout: true,
      env: [
        {"MIX_HOME", Path.join(context.root, ".mix")},
        {"HEX_HOME", Path.join(context.root, ".hex")}
      ]
    )
  end

  defp snapshot(root, environment) do
    JSON.decode!(File.read!(Path.join(root, "lock.json")))["environments"][environment]
  end

  test "dependency environments are evaluated independently from the root and runtime false survives",
       c do
    project(
      c.root,
      :root,
      "[{:build_only, path: \"build_only\", only: [:dev, :test], runtime: false, env: :test}]"
    )

    project(
      Path.join(c.root, "build_only"),
      :build_only,
      "if(Mix.env() == :test, do: [{:leaf, path: \"../leaf\"}], else: [])"
    )

    project(Path.join(c.root, "leaf"), :leaf, "[]")
    assert {_, 0} = sync(c)
    dev = snapshot(c.root, "dev")

    assert [%{"app" => "build_only", "runtime" => false, "environment" => "test"}] =
             dev["root"]["dependencies"]

    assert dev["packages"]["build_only"]["environment"] == "test"
    assert [%{"app" => "leaf"}] = dev["packages"]["build_only"]["dependencies"]
    assert snapshot(c.root, "prod")["packages"] == %{}
  end

  test "unselected optional edges are absent and selected optional edges retain their meaning",
       c do
    project(c.root, :root, "[{:parent, path: \"parent\"}]")
    project(Path.join(c.root, "parent"), :parent, "[{:leaf, path: \"../leaf\", optional: true}]")
    project(Path.join(c.root, "leaf"), :leaf, "[]")
    assert {_, 0} = sync(c)
    assert snapshot(c.root, "dev")["packages"]["parent"]["dependencies"] == []

    project(c.root, :root, "[{:parent, path: \"parent\"}, {:leaf, path: \"leaf\"}]")
    assert {_, 0} = sync(c)

    assert [%{"app" => "leaf", "optional" => true}] =
             snapshot(c.root, "dev")["packages"]["parent"]["dependencies"]
  end

  test "check detects declaration drift without rewriting the manifest", c do
    project(c.root, :root, "[{:leaf, path: \"leaf\", runtime: false}]")
    project(Path.join(c.root, "leaf"), :leaf, "[]")
    assert {_, 0} = sync(c)
    original = File.read!(Path.join(c.root, "lock.json"))
    assert {_, 0} = sync(c, ["--check"])
    assert {_, 0} = sync(c)
    assert File.read!(Path.join(c.root, "lock.json")) == original
    project(c.root, :root, "[{:leaf, path: \"leaf\", runtime: true}]")
    {message, status} = sync(c, ["--check"])
    assert status != 0
    assert message =~ "dependency manifest drift"
    assert File.read!(Path.join(c.root, "lock.json")) == original
  end

  test "missing sources fail instead of producing incomplete package stubs", c do
    project(c.root, :root, "[{:missing, path: \"missing\"}]")
    {message, status} = sync(c)
    assert status != 0
    assert message =~ "run mix deps.get explicitly"
    refute File.exists?(Path.join(c.root, "lock.json"))
  end

  test "configuration edits do not change the manifest", c do
    project(c.root, :root, "[]")
    File.mkdir_p!(Path.join(c.root, "config"))

    File.write!(
      Path.join(c.root, "config/config.exs"),
      "import Config\nconfig :root, marker: :first\n"
    )

    assert {_, 0} = sync(c)
    original = File.read!(Path.join(c.root, "lock.json"))
    refute original =~ "config.exs"

    File.write!(
      Path.join(c.root, "config/config.exs"),
      "import Config\nconfig :root, marker: :changed\n"
    )

    assert {_, 0} = sync(c, ["--check"])
    assert {_, 0} = sync(c)
    assert File.read!(Path.join(c.root, "lock.json")) == original
  end

  test "conflicting path identities fail instead of choosing a dependency", c do
    project(c.root, :root, "[{:parent, path: \"parent\"}, {:leaf, path: \"leaf\"}]")
    project(Path.join(c.root, "parent"), :parent, "[{:leaf, path: \"../other_leaf\"}]")
    project(Path.join(c.root, "leaf"), :leaf, "[]")
    project(Path.join(c.root, "other_leaf"), :leaf, "[]")
    {message, status} = sync(c)
    assert status != 0
    assert message =~ "overriding a child dependency"
    refute File.exists?(Path.join(c.root, "lock.json"))
  end

  test "an explicit Mix override selects the root dependency consistently", c do
    project(
      c.root,
      :root,
      "[{:parent, path: \"parent\"}, {:leaf, path: \"leaf\", override: true}]"
    )

    project(Path.join(c.root, "parent"), :parent, "[{:leaf, path: \"../other_leaf\"}]")
    project(Path.join(c.root, "leaf"), :leaf, "[]")
    project(Path.join(c.root, "other_leaf"), :leaf, "[]")

    assert {_, 0} = sync(c)
    graph = snapshot(c.root, "dev")
    assert graph["packages"]["leaf"]["source"] == %{"type" => "path", "path" => "leaf"}
    assert Enum.find(graph["root"]["dependencies"], &(&1["app"] == "leaf"))["override"]
    assert [%{"app" => "leaf"}] = graph["packages"]["parent"]["dependencies"]
  end

end
