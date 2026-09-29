ExUnit.start()

defmodule LegacyInteropTest do
  use ExUnit.Case

  test "legacy consumers load Mix application code and generated resources" do
    assert SampleDep.answer() == 42
    assert SampleDep.generated() == "dependency alias ran"
  end
end
