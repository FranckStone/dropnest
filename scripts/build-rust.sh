#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
cargo build --locked --release --manifest-path rust/filecheck/Cargo.toml --target-dir "$PWD/.build/rust"
