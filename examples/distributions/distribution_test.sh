#!/usr/bin/env bash
set -euo pipefail
export PATH="$ERLANG_HOME/bin:$PATH"
# rootpaths expands to the distribution directory and the version evidence file.
for artifact in $1; do
    if [[ -d "$artifact/bin" ]]; then
        "$artifact/bin/elixir" -e '
          unless System.version() == "1.20.3", do: raise("unexpected Elixir version")
          Mix.start()
          unless Mix.env() == :dev, do: raise("Mix did not start")
        '
        exit 0
    fi
done
echo "Elixir distribution missing from runfiles" >&2
exit 1
