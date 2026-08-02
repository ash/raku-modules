#!/bin/sh
# Run every distribution's tests under both engines.
#
#   ./test.sh              # all distributions
#   ./test.sh HTTP-Simple  # just one
#
# Set RAKUPP to point at a particular Raku++ binary; it defaults to `rakupp`
# on PATH.

set -e
cd "$(dirname "$0")"

RAKU=${RAKU:-raku}
RAKUPP=${RAKUPP:-rakupp}

dists=${*:-$(find . -maxdepth 2 -name META6.json -not -path './.*' \
             | sed 's|^\./||; s|/META6.json$||' | sort)}

failed=0
for dist in $dists; do
    for engine in "$RAKU" "$RAKUPP"; do
        for t in "$dist"/t/*.t "$dist"/t/*.rakutest; do
            [ -f "$t" ] || continue
            if out=$("$engine" -I"$dist/lib" "$t" 2>&1); then
                printf '%-10s %-28s %s ok\n' "$(basename "$engine")" "$t" \
                       "$(printf '%s\n' "$out" | grep -c '^ok ')"
            else
                printf '%-10s %-28s FAILED\n' "$(basename "$engine")" "$t"
                printf '%s\n' "$out" | sed 's/^/    /'
                failed=1
            fi
        done
    done
done

exit $failed
