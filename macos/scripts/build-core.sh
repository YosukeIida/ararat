#!/bin/sh
# Builds the Rust core as a static library and regenerates its Swift bindings.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
core="$here/../core"
cd "$core"
cargo build --release -p ararat-ffi
out=$(mktemp -d)
cargo run -q --release --bin uniffi-bindgen -- generate \
  --library target/release/libararat_ffi.dylib --language swift --out-dir "$out"
mkdir -p "$here/Sources/ararat_ffiFFI/include"
cp "$out/ararat_ffiFFI.h" "$here/Sources/ararat_ffiFFI/include/"
cp "$out/ararat_ffiFFI.modulemap" "$here/Sources/ararat_ffiFFI/include/module.modulemap"
mkdir -p "$here/Sources/AraratKit"
cp "$out/ararat_ffi.swift" "$here/Sources/AraratKit/Generated.swift"
