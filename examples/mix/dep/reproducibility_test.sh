#!/usr/bin/env bash
set -euo pipefail
# The targets compile the same sources in separate actions and temporary roots.
original=""
repeated=""
group=""
for artifact in "$@"; do
    case "$artifact" in
        --first|--second) group="$artifact" ;;
        */ebin)
            if [[ "$group" == --first ]]; then
                original="${artifact%/ebin}"
            else
                repeated="${artifact%/ebin}"
            fi
            ;;
    esac
done
test -n "$original"
test -n "$repeated"
diff -r "$original" "$repeated"
