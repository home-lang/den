# WebAssembly Plugin Example

`math.zig` is a tiny plugin compiled to WebAssembly and loaded by Den's built-in
WASM host (`src/plugins/wasm.zig`).

## Build

```sh
zig build-exe math.zig -target wasm32-freestanding -fno-entry -O ReleaseSmall \
  --export=add --export=mul --export=fib -femit-bin=math.wasm
```

A prebuilt `math.wasm` (~160 bytes) is checked in.

## Run from Den

```sh
wasm --exports ./math.wasm     # fib, mul, add
wasm ./math.wasm add 17 25     # 42
wasm ./math.wasm mul 6 7       # 42
wasm ./math.wasm fib 20        # 6765
```

## Writing your own

Export functions taking and returning `i32`/`i64`. Any language that targets
`wasm32` works (Zig, C/Clang, Rust). The interpreter supports the core integer
instruction set, structured control flow, function calls, and linear-memory
load/store.
