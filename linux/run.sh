#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# Optional local development headers; otherwise use the distribution's packages.
deck_pkgconfig="${XDG_CACHE_HOME:-$HOME/.cache}/openagentdeck/devel/usr/lib64/pkgconfig"
if [[ -d "$deck_pkgconfig" ]]; then
    export PKG_CONFIG_PATH="$deck_pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
fi
exec cargo run --locked --manifest-path "$script_dir/Cargo.toml" -- "$@"
