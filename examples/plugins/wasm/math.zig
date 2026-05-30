//! Example WebAssembly plugin for Den.
//!
//! Build:
//!   zig build-exe math.zig -target wasm32-freestanding -fno-entry \
//!     -O ReleaseSmall --export=add --export=mul --export=fib \
//!     -femit-bin=math.wasm
//!
//! Use from Den:
//!   wasm ./math.wasm add 17 25     # 42
//!   wasm ./math.wasm fib 10        # 55
export fn add(a: i32, b: i32) i32 {
    return a +% b;
}

export fn mul(a: i32, b: i32) i32 {
    return a *% b;
}

export fn fib(n: i32) i32 {
    var a: i32 = 0;
    var b: i32 = 1;
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        const t = a +% b;
        a = b;
        b = t;
    }
    return a;
}
