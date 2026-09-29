#!/usr/bin/env bash
set -euo pipefail
export ERL_FLAGS="${ERL_FLAGS:-} +fnu"
cd "$TEST_TMPDIR"
cp -RL "$TEST_SRCDIR/$TEST_WORKSPACE/release" server
cp -RL "$TEST_SRCDIR/$TEST_WORKSPACE/load_only" client
chmod -R u+w server client
server/bin/sample eval '
  unless Sample.Unicode.greeting() == "Olá, café!\n", do: raise("UTF-8 resource changed")
  unless Sample.answer() == 42 and SampleNative.answer() == 42 and Sample.Generated.answer() == 42, do: raise("compiled dependency changed")
  unless Sample.config_marker() == :prod, do: raise("dependency did not inherit root prod config")
  unless Sample.resource() == "declared resource\n", do: raise("priv missing")
  unless File.read!(Application.app_dir(:sample, "priv/root_alias.txt")) == "root alias ran", do: raise("compile alias resource missing")
  unless Application.get_env(:sample, :runtime_marker) == :loaded, do: raise("runtime config missing")
  unless :code.which(Sample.Support) == :non_existing, do: raise("test sources leaked into release")
  unless :code.lib_dir(:sample_dep) == {:error, :bad_name}, do: raise("compile-only app leaked into release")
  {:ok, _} = Application.ensure_all_started(:sample)
'
client/bin/load_only eval '
  unless Application.get_env(:sample, :runtime_marker) == nil, do: raise("disabled runtime config executed")
  [rel] = Path.wildcard(Path.join(System.fetch_env!("RELEASE_ROOT"), "releases/*/load_only.rel"))
  {:ok, [{:release, _, _, apps}]} = :file.consult(String.to_charlist(rel))
  unless {:sample, ~c"0.1.0", :load} in apps, do: raise("named application mode lost")
'
