"""Exercise persistent compiler history through observable ExUnit behavior."""

import os
from pathlib import Path
import re
import subprocess
import time

os.chdir(Path(__file__).resolve().parent)
bazel = os.environ.get("BAZEL", "bazel")
leaf = Path("lib/worker_leaf.ex")
resource = Path("priv/message.txt")
added = Path("lib/worker_removable.ex")
dependency = Path("dep/lib/sample_dep.ex")
config = Path("config/config.exs")
original_leaf = leaf.read_text()
original_resource = resource.read_text()
original_dependency = dependency.read_text()
original_config = config.read_text()
assert not added.exists()


def run(value=11, module="absent", message="declared resource\n", dep=42, marker="test", broken=False, cold=False, state="any"):
    """Build the tests; state is the worker's expected decision for the root application, if any."""
    command = [bazel, "build" if broken else "test", "//:test", "--jobs=4",
               "--worker_max_instances=1", "--worker_sandboxing",
               "--strategy=MixCompile=" + ("sandboxed" if cold else "worker,sandboxed"),
               # Every step must reach the compiler: no disk or remote cache.
               "--remote_accept_cached=false", "--disk_cache="]
    if not broken:
        command += ["--test_sharding_strategy=disabled", "--test_output=errors",
                    "--test_arg=test/worker_test.exs", f"--test_env=EXPECTED_WORKER_VALUE={value}",
                    f"--test_env=EXPECTED_WORKER_MODULE={module}",
                    f"--test_env=EXPECTED_WORKER_DEPENDENCY={dep}",
                    f"--test_env=EXPECTED_WORKER_CONFIG={marker}",
                    f"--test_env=EXPECTED_WORKER_RESOURCE={message}"]
    started = time.monotonic()
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    print(result.stdout, flush=True)
    decisions = re.findall(r"Mix compiler state: (\w+) \((\d+) inputs hashed by the worker\)", result.stdout)
    print(f"WORKER CHECK: value={value} module={module} broken={broken} cold={cold} decisions={decisions} seconds={time.monotonic()-started:.3f}", flush=True)
    assert (result.returncode != 0) == broken, result.stdout
    if state != "any":
        assert [decision for decision, _ in decisions] == ([state] if state else []), (state, decisions)


try:
    # Start from no outputs, so the first build reaches the worker that the
    # following steps reuse. Whether that worker is new or left over from an
    # earlier invocation, its decision here depends on what it last compiled.
    subprocess.run([bazel, "clean"], check=True)
    run()
    # Ordinary .ex edits, additions and removals keep the compiler state.
    leaf.write_text(original_leaf.replace("11", "22"))
    run(value=22, state="reused")
    added.write_text("defmodule Sample.WorkerRemovable do\n  def value, do: :present\nend\n")
    run(value=22, module="present", state="reused")
    added.unlink()
    run(value=22, state="reused")
    # A failed compilation discards the state, so the next request resets.
    leaf.write_text("defmodule Sample.WorkerLeaf do\n  this is not valid Elixir !!!\n")
    run(broken=True, state="reused")
    leaf.write_text(original_leaf.replace("11", "33"))
    run(value=33, state="reset")
    # Any other declared input identifies the state.
    resource.write_text("updated resource\n")
    run(value=33, message="updated resource\n", state="reset")
    dependency.write_text(original_dependency.replace("do: 42", "do: 43"))
    run(value=33, message="updated resource\n", dep=43, state="reset")
    config.write_text(original_config.replace("config_env()", ":worker"))
    run(value=33, message="updated resource\n", dep=43, marker="worker", state="reset")
    # Removing outputs forces a clean build of the same final source, without a worker.
    subprocess.run([bazel, "clean"], check=True)
    run(value=33, message="updated resource\n", dep=43, marker="worker", cold=True, state=None)
finally:
    leaf.write_text(original_leaf)
    resource.write_text(original_resource)
    dependency.write_text(original_dependency)
    config.write_text(original_config)
    added.unlink(missing_ok=True)
