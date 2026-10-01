# Editor native bindings

`include/pragtical_hx/native.h` is the editor's public C binding contract.
`scripts/update-native-bindings.sh` generates `bindings/pragtical_hx.hxi`
through Haxeon's Clang importer and audits identical ABI layouts across
Linux, Windows and both macOS architectures. `--check` verifies the committed
binding; the headless suite runs this check. The projection map exposes
`platform.ffi.NativeApi` and `NativeTypes`.

ABI 18 replaces the HashLink-specific bridge with an ordinary C shared library.
Strings use explicit NUL-terminated UTF-8 contracts. Results are borrowed and
copied by Haxeon before returning to application code; process output retains
partial scalars across native reads. Boolean inputs and results use an annotated
32-bit representation, matching NativeKit's portable convention. Runtime
platform checks still reject incompatible ABI versions.

`platform.Native` retains the plugin dispatch callback handle while C holds its
function pointer. Replacement installs the new pointer before closing the old
handle. Shutdown unregisters it before closure. Callback failures are polled and
converted from managed UTF-8 bytes into application exceptions; they never
unwind through C. The dynamic SDK declares the same C symbol through HXI;
embedding and restoring the plugin compiler remains a separate baseline task.

The unused SDL host callbacks and `host.h` are removed. Window, font, frame,
event and drawing functions remain because the model tests, deterministic
renderer and performance fixtures exercise them. They describe the headless
model, while UIKit owns graphical windows, input, clipboard and painting.
Removing these APIs requires migrating their consumers, not deleting coverage.

The retention annotation precedes nullable callback parameters. Clang 18's JSON
AST replaces `CB _Nullable` with the trailing annotation macro's name when that
macro follows the parameter; placing the annotation first preserves its original
semantics and yields `nullable<CB> @retained` in the generated interface.
The platform audit validates the emitted declaration on all four targets.
