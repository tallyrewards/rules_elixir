import Config
config :sample, :compile_marker, config_env()
config :sample, :test_partition, System.get_env("MIX_TEST_PARTITION")
