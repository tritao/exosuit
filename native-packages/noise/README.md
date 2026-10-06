# NoiseKit

NoiseKit is Exosuit's narrow C and Haxeon boundary around the pinned Noise-C
submodule. It implements only `Noise_XX_25519_ChaChaPoly_SHA256`; callers cannot
select a different protocol suite or cipher.

Native builds use Noise-C's operating-system entropy source. Emscripten builds
replace it with `crypto.getRandomValues` and abort if secure browser entropy is
unavailable. The package does not fall back to a weak random source.

The generated HXI is audited for the supported 64-bit desktop ABIs. The web
build generates a separate `portable-abi32` HXI and links NoiseKit into the
Emscripten host. `NoiseSession` owns the Haxe-facing handshake lifetime;
workspace transport classes bind machine and device routes, pin static keys,
and admit RPC only after authentication.

The upstream library is pinned at `cfe25410979a87391bb9ac8d4d4bef64e9f268c6`
under `vendor/noise-c/`. Noise-C describes itself as a reference
implementation; this integration has not received an independent security
audit. Review the fixed suite, key storage and pairing flow before enabling
first-time remote access for users.

Run the C contract, generated ABI audit and managed Haxe contract with:

```sh
native-packages/noise/tests/run.sh
```
