"""An edit must rerun only the actions that read it."""

import json
import os
from pathlib import Path
import subprocess
import tempfile

os.chdir(Path(__file__).resolve().parent)
bazel = os.environ.get("BAZEL", "bazel")
config = Path("config/config.exs")
original = config.read_text()
test = Path("test/sample_test.exs")
original_test = test.read_text()
log = Path(tempfile.mkdtemp()) / "execution.json"


def build(*targets):
    """Build the targets and return the (mnemonic, target) of each spawn that ran."""
    targets = targets or ("//:app", "//dep:app")
    subprocess.run([bazel, "build", *targets, f"--execution_log_json_file={log}"], check=True)
    decoder, text, spawns, index = json.JSONDecoder(), log.read_text(), set(), 0
    while index < len(text):
        if text[index].isspace():
            index += 1
            continue
        spawn, index = decoder.raw_decode(text, index)
        spawns.add((spawn.get("mnemonic"), spawn.get("targetLabel", "").lstrip("@")))
    return spawns


def compiled(spawns, target):
    return {mnemonic for mnemonic, label in spawns if label.endswith(target) and mnemonic in ("MixCompile", "MixConfigure")}


def marker():
    bin_dir = subprocess.run([bazel, "info", "bazel-bin"], check=True, capture_output=True, text=True).stdout.strip()
    ebin = f"{bin_dir}/dep/app/sample_dep/ebin"
    return subprocess.run(["elixir", "-pa", ebin, "-e", "IO.write(SampleDep.config_marker())"], check=True, capture_output=True, text=True).stdout


try:
    build()
    assert marker() == "dev", marker()

    config.write_text(original + "config :sample, :unrelated, :edited\n")
    spawns = build()
    assert compiled(spawns, "//dep:app") == set(), spawns
    assert compiled(spawns, "sample_deps//:jason") == set(), spawns
    assert "MixCompile" in compiled(spawns, "//:app"), spawns

    config.write_text(original.replace("config_env()", ":edited"))
    spawns = build()
    assert compiled(spawns, "//dep:app") == {"MixConfigure"}, spawns
    assert marker() == "edited", marker()
    config.write_text(original)

    # Test files are inputs of the test, not of the compiled application.
    build("//:test")
    test.write_text(original_test + "# edited\n")
    spawns = build("//:test")
    assert not {mnemonic for mnemonic, _ in spawns} & {"MixCompile", "MixConfigure"}, spawns
    print("invalidation: ok")
finally:
    config.write_text(original)
    test.write_text(original_test)
