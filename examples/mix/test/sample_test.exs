defmodule SampleTest do
  use ExUnit.Case

  test "UTF-8 source and resource paths survive compilation and staging" do
    assert Sample.Unicode.greeting() == "Olá, café!\n"
    assert File.read!(Application.app_dir(:sample, "priv/café.txt")) == "Olá, café!\n"
  end

  test "precompiled dependency and priv remain available" do
    assert :telemetry.execute([:sample, :test], %{value: 42}) == :ok
    assert Sample.answer() == 42
    assert Sample.generated() == "dependency alias ran"
    assert Sample.native_answer() == 42
    assert SampleNative.answer() == 42
    assert SampleNative.generated() == "declared tool data\n"
    assert Sample.Generated.answer() == 42
    assert Sample.config_marker() == :test
    assert Sample.root_env() == "test"
    assert Sample.resource() == "declared resource\n"
    assert File.read!(Application.app_dir(:sample, "priv/root_alias.txt")) == "root alias ran"
    assert Sample.Support.environment() == :test
    assert Jason.decode!(~s({"answer":42})) == %{"answer" => 42}
  end
end
