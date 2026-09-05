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

# Each distribution is tested from ITS OWN directory, so that a module looking
# for its compiled half at resources/libraries/... finds it in a checkout the
# way it would once installed. (%?RESOURCES answers in an uninstalled tree on
# Rakudo but not on Raku++, and Raku++ is where the compiled half matters, so
# $*CWD is the candidate that has to work.) A relative RAKU/RAKUPP would not
# survive that, so resolve them here.
abspath() {
    case "$1" in
        */*) ( cd "$(dirname "$1")" && printf '%s/%s\n' "$(pwd)" "$(basename "$1")" ) ;;
        *)   printf '%s\n' "$1" ;;
    esac
}
RAKU=$(abspath "$RAKU")
RAKUPP=$(abspath "$RAKUPP")

dists=${*:-$(find . -maxdepth 2 -name META6.json -not -path './.*' \
             | sed 's|^\./||; s|/META6.json$||' | sort)}

failed=0
for dist in $dists; do
    for engine in "$RAKU" "$RAKUPP"; do
        for t in "$dist"/t/*.t "$dist"/t/*.rakutest; do
            [ -f "$t" ] || continue
            if out=$(cd "$dist" && "$engine" -Ilib "t/$(basename "$t")" 2>&1); then
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
