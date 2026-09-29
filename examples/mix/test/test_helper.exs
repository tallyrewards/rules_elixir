if expected = System.get_env("EXPECTED_MIX_TEST_PARTITION") do
  import ExUnit.Assertions
  assert System.get_env("MIX_TEST_PARTITION") == expected
  assert Application.fetch_env!(:sample, :test_partition) == expected
end

ExUnit.start()
