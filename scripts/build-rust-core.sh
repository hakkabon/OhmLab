#!/usr/bin/env bash
#
# Builds the optional Rust simulation core (ohm-core) and stages the artefacts
# SwiftPM needs to link it:
#
#   • rust/ohm-core/target/release/libohm_core.a   (static library)
#   • Sources/CCOhmCore/ohm_core.h                 (public header, kept in sync)
#
# After running this, set OHMLAB_RUST_CORE=1 for Swift build/test commands.
# The native Swift engine remains the default and no Rust toolchain is required
# for a normal build.
#
# Usage: scripts/build-rust-core.sh [debug|release]   (default: release)

set -euo pipefail

PROFILE="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE_DIR="$ROOT/rust/ohm-core"

if ! command -v cargo >/dev/null 2>&1; then
    echo "error: cargo (Rust toolchain) not found on PATH." >&2
    echo "       Install from https://rustup.rs/ and re-run." >&2
    exit 1
fi

echo "▸ Running cargo test (ohm-core)…"
( cd "$CRATE_DIR" && cargo test )

if [ "$PROFILE" = "debug" ]; then
    CARGO_FLAGS=""
else
    CARGO_FLAGS="--release"
fi

echo "▸ Building libohm_core ($PROFILE)…"
( cd "$CRATE_DIR" && cargo build $CARGO_FLAGS )

echo "▸ Syncing public header into Sources/CCOhmCore…"
cp "$CRATE_DIR/include/ohm_core.h" "$ROOT/Sources/CCOhmCore/ohm_core.h"

echo "✓ Done. Static library:"
ls -l "$CRATE_DIR/target/$PROFILE/libohm_core.a"
echo
echo "Run OHMLAB_RUST_CORE=1 swift test to compile and exercise the bridge."
