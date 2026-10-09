# TextMate regular expressions

This Haxeon package exposes an ordered Oniguruma scanner for TextMate grammars.
The editor uses the same package in HashLink desktop builds and in the
Emscripten browser host.

Oniguruma is pinned at `f95747b462de672b6f8dbdeb478245ddf061ca53`
(version 6.9.10) as a source submodule under `vendor/oniguruma`. Its license is
in `vendor/oniguruma/COPYING`.

The C API owns compiled expressions and returns match and capture offsets in
UTF-8 bytes. The Haxe adapter shares a per-line UTF-8 snapshot and converts
those offsets to the editor's UTF-16 columns. The scanner has limits for
pattern count and size, line size, nesting, retries, stack use, and match time.

Regenerate or verify the portable Haxeon interface with:

```sh
tools/update-hxi.sh
tools/update-hxi.sh --check
```

Run the native contract test with:

```sh
cmake -S . -B tests/build/native -G Ninja -DCMAKE_BUILD_TYPE=Debug -DBUILD_TESTING=ON
cmake --build tests/build/native
ctest --test-dir tests/build/native --output-on-failure
```
