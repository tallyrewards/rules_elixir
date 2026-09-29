defmodule Sample.WorkerTest do
  use ExUnit.Case

  test "compile-time references observe the current source and resource" do
    expected = String.to_integer(System.get_env("EXPECTED_WORKER_VALUE", "11"))
    assert Sample.WorkerLeaf.value() == expected
    assert Sample.WorkerConsumer.value() == expected

    assert Sample.answer() ==
             String.to_integer(System.get_env("EXPECTED_WORKER_DEPENDENCY", "42"))

    assert Atom.to_string(Sample.config_marker()) ==
             System.get_env("EXPECTED_WORKER_CONFIG", "test")

    assert Sample.WorkerConsumer.message() ==
             System.get_env("EXPECTED_WORKER_RESOURCE", "declared resource\n")
  end

  test "removed source modules are absent from the compiled application" do
    assert Code.ensure_loaded?(Sample.WorkerRemovable) ==
             (System.get_env("EXPECTED_WORKER_MODULE") == "present")
  end
end
