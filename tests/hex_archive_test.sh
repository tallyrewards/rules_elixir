#!/usr/bin/env bash
set -euo pipefail
export PATH="$ERLANG_HOME/bin:$PATH"
"$ELIXIR_HOME/bin/elixir" -e '
  [archive] = System.argv()
  {:ok, entries} = :zip.extract(String.to_charlist(archive), [:memory])
  paths = Enum.map(entries, fn {path, _} -> to_string(path) end)
  unless Enum.any?(paths, &String.ends_with?(&1, "/ebin/mix_hex_core.beam")),
    do: raise("Hex archive is missing its Erlang implementation")
  unless Enum.any?(paths, &String.ends_with?(&1, "/ebin/Elixir.Hex.beam")),
    do: raise("Hex archive is missing its Elixir implementation")
' "$1"
