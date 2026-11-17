# Haxeon compiler bugs

Bugs in the haxeon compiler that we hit while working on exosuit, with what we know about each. Add every one you
find, even when you work around it, so there is a record. A behaviour that may be deliberate (haxeon is stricter
than stock Haxe in places) is listed under "Unclear" until someone decides.

Each entry: the symptom (the exact error), a minimal repro if we have one, what we think causes it, the workaround,
and the status.

## Open

Found during the port to haxeon upstream `ff7e29aac` + our commits (`exosuit-upstream` 5d2c7ab19), 2026-11-17. The
repro folders named below are under `.port/out/` in the port worktree (not in git); each entry has the minimal source.

### An empty array literal nested in an object inside an array: "element type ... reached IR generation unresolved"

- **Symptom:** `Internal error: the type of the element type of this empty array reached IR generation unresolved`,
  with no file or line, after typing succeeds. Seen at `src/syntax/BuiltinSyntax.hx:227` (`patterns: []`).
- **Repro:** `static function g():Dynamic return {patterns: [{patterns: []}]};` fails; `{patterns: []}` alone and
  `{patterns: [{patterns: ([] : Array<Dynamic>)}]}` compile (`S2/emptyarray`).
- **Cause:** not known. The empty array's element type is left as an open monomorph when the expected type is Dynamic.
- **Workaround:** `([] : Array<Dynamic>)` (BuiltinSyntax).
- **Status:** open.

### A default argument value is resolved in the caller's module, not the declaring one

- **Symptom:** `E1005: Unknown variable "config"` for `delaySeconds:Float = config.Settings.DEFAULT_TOOLTIP_DELAY`
  (`graphical/src/ui/TabTooltip.hx`) unless some other module of the closure loaded `config.Settings`; and
  `E1005: Unknown variable "MessagePackReader"` in any module that uses `haxeon.wire.MessagePackFrame`, whose
  `?maxPayload:Int = MessagePackReader.DEFAULT_MAX_BYTES` names a same-package type the caller does not import.
- **Repro:** `a.Tip` with `new(delay:Float = b.Const.DELAY)` and `app.Main` doing `new a.Tip()` gives
  `Tip.hx:5:36: E1005: Unknown variable "b"` (`U2/repro-default-arg`). A Main that only calls
  `MessagePackFrame.payloadLength(Bytes.alloc(MessagePackFrame.HEADER_BYTES), 100)` (`S1a/wire-repro`).
- **Cause:** the default value expression is typed at the call site, in the caller's import scope.
- **Workaround:** import the type in the declaring module and use its short name (TabTooltip); for MessagePackFrame,
  import `haxeon.wire.MessagePackReader` in the caller as well (NativeRpcTransport, RelayFrameCodec, RelayFrameReader).
- **Status:** open.

### A type of a parent package, or a generated module of the same package, is found only if something loaded it

- **Symptom:** `package a.b; class Child { var p:Parent; }` with `a.Parent` imported nowhere else gives
  `E1020 Unknown type "Parent"` (stock Haxe resolves parent packages). Hit by `ui.control.EditorControl`
  (`ui.ExosuitApp`) and `exohost.control.ControlRouter`, `ExohostCtl`, `exohost.remote.MachineRemote`. The same shape:
  `-Entry editor.GutterGeometry` stops in haxeon's generated binding `haxeon/ui/ResolvedLayoutItem.hx:156` with
  `E1005 Unknown variable "NativeKitUIConstants"`; the whole app build loads that module first and is not affected.
- **Repro:** `U8/repro-parentpkg`.
- **Cause:** module lookup does not walk up the package path, and does not load a module of the current package by
  name on demand.
- **Workaround:** explicit imports.
- **Status:** open.

### A lambda with an untyped parameter and a declared return type, assigned to `Null<A->B>`: E1020 at an unrelated file

- **Symptom:** `holder.f = function(_):Int return 1;` with `var f:Null<String->Int>` fails with
  `E1020 Unresolved inferred type` reported at `stdlib/EReg.hx:1:1` or `stdlib/StringBuf.hx:76:1`, not at the lambda.
  `function(_) return 1`, or a field type without `Null<>`, compiles.
- **Repro:** `X1/repro-nullfn`.
- **Workaround:** type the parameter (`function(_:String):Int ...`).
- **Status:** open.

### A method of a generic instance passed as a function value: "Conflicting generic method reference"

- **Symptom:** `directories.forAgent(..., ctx.fail)` with `ctx:RpcContext<AgentView>` in one provider and
  `RpcContext<AgentRecord>` in another fails with `Conflicting generic method reference
  "$generic-method-reference:haxeon.rpc.RpcContext:fail..."`.
- **Workaround:** a lambda, `error -> ctx.fail(error)` (ClaudeProvider, CodexProvider, PiProvider).
- **Status:** open, no minimal repro.

### Enum values with class payloads cannot be compared, against what LANGUAGE_SUPPORT.md says

- **Symptom:** `Array<UiEditorTab>.indexOf/remove` and `==` give `E1025 ... does not conform to Equatable`; declaring
  `Equatable` fails too (`E1025 "Settings.settings does not conform"`) because a constructor holds a plain class.
  `docs/reference/LANGUAGE_SUPPORT.md:49-51` says such values compare by identity and that `indexOf`/`remove` use the
  same rule.
- **Repro:** `U8/repro-enum-identity`.
- **Workaround:** compare the held object (`UiWorkbenchHost.tabIndex`, `removeTab`).
- **Status:** open; the docs or the compiler is wrong.

### Several probe compiles of one package at once: intermittent internal errors in the worker

- **Symptom:** with several `-Entry` probes of one project running at the same time, the worker sometimes fails with
  `Cached function "workspace.client.AgentHistoryWindow.new" has no source owner`, `Missing target for generic method
  reference "$generic-method-reference:haxeon.platform.async.Promise:cancel:..."` or `IR verification failed ...
  Unknown IR closure target "workspace.service.WorkspaceTerminalProtocol.encodeChange"`. Each passes when run again
  alone; the whole-project builds never showed it.
- **Cause:** not known; probably shared cached state between requests of different entries.
- **Status:** open, no repro.

### `Array.remove` and `indexOf` in a generic instance over an array type: "Unknown IR call __array_remove_any"

- **Symptom:** `activeJobs.remove(cast job)` (`activeJobs:Array<ScmJob<Dynamic>>`) in the generic `finish<T>` and
  `newJob<T>` of `src/scm/RpcScmSource.hx` fails only where the instance has `T = Array<ScmBranch>` (tests/workspace-scm):
  `IR verification failed for $generic:scm.RpcScmSource.finish[layout]<Array<class:scm.ScmBranch<>>>: Unknown IR call
  "__array_remove_any"`; `indexOf` gives `__array_index_of_any` the same way. The app's own build does not reach that
  instance.
- **Repro:** put back `activeJobs.remove(cast job)` in RpcScmSource and compile tests/workspace-scm.
- **Cause:** not known; the array-equality helper for an element type that is itself an instance of a generic class
  over an array is not generated.
- **Workaround:** a `forgetJob` loop with `splice` (RpcScmSource).
- **Status:** open, no minimal repro.

### UIKit: a positioned Tooltip inside a TrackedScope that runs alone: "Layout node IDs must be unique"

- **Symptom:** a `TrackedScope` whose body holds a Tooltip with a placement (its tip node is `overlay`, lifted by the
  window's `TooltipOverlayHost`) throws `Layout node IDs must be unique` at the next submit as soon as the scope runs
  alone (no root build): after a signal it read was written between frames, and after a State its body read was
  written in `onResolved`. Seen once as "A render scope body must produce its reserved, unparented root". The same tree
  built at the root runs. Also, `ScopeRootBoundary.transferNodeFields` does not carry a caller-set
  `commandShortcutFilter` to the root a re-run builds, and caller closures that captured the old root read its stale
  geometry.
- **Repro:** `F3/repro` (`main.hl plain|scope|signal`: plain passes, scope and signal throw); in the app,
  tests/terminal-context-menu at 2da8ddb2 (the whole TerminalPane in its scope with the control strip's status
  Tooltip).
- **Workaround:** keep Tooltips and caller-decorated nodes out of a scope that re-runs alone: the terminal's scope
  covers its rows only (b6853624), and the status bar (a TabTooltip on every slot) is not scoped, so caret, selection
  and text changes still rebuild the root.
- **Status:** open.

### An edit to AutomationProbe.hx makes its hlNative extern "not return on every path"

- **Symptom:** seen 2026-11-16 on haxeon fa128931e (exosuit main a457e3dc): adding one line to
  `AutomationProbe.poll()` (`if (sys.FileSystem.exists(directory + "/pause")) return;`) and running
  `scripts/build-windows.ps1 -SkipBootstrap` fails with `devtools/AutomationProbe.hx:21:8: E1006: Function
  devtools.AutomationProbe.preparePrivateDirectory does not return on every path`. Line 21 is an untouched
  `@:hlNative("haxeon_runtime", "__host_prepare_private_directory") extern function ...:Bool;` with no body.
  The unedited file builds.
- **Cause:** not known. The return-path check seems to run on a bodiless native extern once the module is typed again.
- **Workaround:** the same check in the caller (GraphicalMain) instead of the probe. Not tried on a later haxeon.
- **Status:** open, no minimal repro.

### The browser build stops before type checking: noisekit has no wasm32 provider

- **Symptom:** `scripts/haxeon_cli.py build --project web/haxeon.json` (also with `--compiler-only`) ends at once with
  `haxeon: Package noisekit cannot be built for wasm32: noisekit -> native dependency noisekit / no wasm32 provider is
  available`. Nothing in the browser sources is type-checked.
- **Cause:** native-packages/noise declares only native providers. The browser client needs Noise (pairing and every
  machine channel go through `NoiseSession`), so it needs a wasm32 provider of noisekit (an Emscripten build of
  noise-c, like the other kits' wasm32 builds) or a haxeon option to type-check a project without resolving native
  providers.
- **Workaround:** none in exosuit. The browser client (web/src/app: `WebMain`, `BrowserPairedMachines`) is written
  against the shared device client (`DevicePairing`, `RemoteMachines`, `RemoteMachine`, `WorkspaceLink`), which the
  phone build compiles; the browser-only files are checked by reading only.
- **Found:** 2026-11-16, entropy Step 8 (browser rebuilt on exohost). Also needs Emscripten in the worktree to link.

### An empty `package;` declaration is a parse error

- **Symptom:** `PhoneSnapshotFile.hx:1:8: E0002: Expected name, got Semicolon` for a file starting with `package;`.
  Stock Haxe accepts an empty package declaration.
- **Workaround:** leave the line out (the root package is the default).
- **Found:** 2026-11-16, entropy Step 8 (the Android module had stopped compiling).

### A field's type is not inferred from an inline static constant

- **Symptom:** `var ownStatus = NOT_PAIRED;` (with `static inline final NOT_PAIRED = "..."`) gives
  `E1002: Cannot infer type of field "ownStatus" from this initializer`. Stock Haxe infers String.
- **Workaround:** write the type: `var ownStatus:String = NOT_PAIRED;`.
- **Found:** 2026-11-16, entropy Step 8 (`RemoteMachines`).

### NativeKit's local listener stops when a client connects and closes before it accepts (runtime, not the compiler)

- **Symptom:** after `pragtical-ctl list` (whose health check opens a pipe and closes it at once) every later
  connection to that pipe waits forever in `WaitNamedPipe`.
- **Cause:** `ListenerResource::run` (haxeon/vendor/nativekit/src/transport/transport.cpp) treats every
  `ConnectNamedPipe` error other than `ERROR_PIPE_CONNECTED` and `ERROR_PIPE_LISTENING` as fatal. A client that
  connected and closed before the call gives `ERROR_NO_DATA`; the listener emits a failure and its thread returns, so
  no new pipe instance is created. That case should disconnect the instance and listen again.
- **Found:** 2026-11-15, entropy Step 9 (exohost's Pragtical pipes).
- **Why it is hit every time:** the pipe is PIPE_NOWAIT and the listener polls `ConnectNamedPipe` every 5 ms, while
  pragtical-ctl's health check connects and closes in well under a millisecond.
- **Workaround (partial):** exohost starts a stopped listener again (PragticalPipes.listen, ExohostDaemon.listen use the
  `failed` callback of NativeRpcHub.listen/listenBytes), so the pipe does not stay dead. It cannot close the gap: the
  new listener's first instance is made with FILE_FLAG_FIRST_PIPE_INSTANCE, so it can start only after the stopped
  listener's handle is closed, and pragtical-ctl connects again at once, into that gap ("failed to connect to local
  transport named pipe"). Only `pragtical-ctl list` works; every command that connects after its health check fails.
- **Fix (in NativeKit):** on `ERROR_NO_DATA`, `DisconnectNamedPipe(current)` and keep listening on the same instance.
- **Status:** open.

### A small edit "retypes ~15000 functions" (investigated, not an invalidation bug)

- **Symptom:** `build-windows.ps1` (and a cold Android build) report `15087 functions retyped` and a 40 to 70 s compile after a
  one-line edit; the frontend log says `restarted: devtools.InspectionAgent.poll needs haxeon.DynamicOps`.
- **Finding 1, the count is the whole program, so the worker was cold.** On the resident worker the same project retypes 3 to 9
  functions for a one-line edit (Android, 2026-11-04: first compile 56 s / 15064 retyped, then 9, 3, 3). Older build logs show
  warm compiles of other projects at 1.8k to 4.1k and graphical cold ones at 15006 to 15099 (39 to 73 s). The worker exits after
  90 s idle (`HAXEON_COMPILER_IDLE_SECONDS`) and its identity includes `PATH`, and the scripts start minutes apart with
  differing `PATH`, so almost every scripted build starts a cold worker. There is no evidence of an edit invalidating the whole
  program.
- **Finding 2, a cold compile types the frontend twice.** `FrontendCompilation.includeTypedRuntimeDependencies` learns about the
  implicit dependency on `haxeon.DynamicOps` only while typing `devtools.InspectionAgent.poll`, adds it to the owning module's
  dependencies and restarts the whole frontend (`frontendRestarts`). Seeding that dependency before the first pass would remove
  the second pass (not done; untested estimate: a third to half of the cold compile).
- **Finding 3, a warm tiny edit still spends ~10 s in IR assembly.** Android, 3 functions retyped: prepare 3.8 s, compile 13.8 s
  of which ir-assembly 10.2 s. The desktop editor in `--live` of this checkout (2026-11-04, one label in `ExosuitApp.hx`, 102
  functions retyped) spent 23 s to the published patch: prepare 4.5 s, compile 18.5 s with ir-assembly 11.4 s, patch applied in
  42 ms. The 3.4 s a developer's editor shows was not reproduced. IR assembly looks proportional to the program, not to the
  edit: the same 10 to 11 s on both projects.
- **Remedies in place:** `build.ps1` no longer deletes `build/haxe`; `dev.ps1 -Live` keeps the worker resident
  (`docs/mobile/android.md`); the desktop loop is the editor in `--live` (`docs/mobile/e2e-local.md`).
- **Status:** findings only. Open items: seed the DynamicOps dependency; make IR assembly incremental.

### A closure in a switch case cannot capture a local declared in that case

- **Symptom:** `CFG generation failed for app.AgentManager.parse: Local "$l11:folder" used before definition`.
- **Shape:** in a `while` loop, `switch value { case "--folder" | "--scratch": var folder = f(); ...
  Lambda.exists(folders, function(existing) return existing == folder) ... }`. Stock Haxe accepts it.
- **Found:** 2026-10-31, M19 Phase 4 (`AgentManager.parse`).
- **Workaround:** no closure: `folders.indexOf(folder) < 0`.
- **Cause:** an or-pattern arm (`case "a" | "b":`, `case 1, 2:`) is typed once per pattern, and each copy
  declares its own locals. Lambdas were cached by position alone, so the second copy's closure reused the first
  copy's, which captures the first copy's locals.
- **Status:** fixed in haxeon `76b31d20` ("Typer: type a lambda once per set of captured bindings"), which keys
  the cache by the captured bindings too.

### "Unreachable statement" after an exhaustive or-pattern switch

- **Symptom:** `E1012: Unreachable statement` on the `return 0`. Stock Haxe accepts it.
- **Repro:**
  ```haxe
  enum E { A(x:Int); B(x:Int); }
  function f(e:E):Int { switch e { case A(n) | B(n): return n; } return 0; }
  ```
- **Suspected cause:** the reachability analysis treats an enum switch that covers every constructor as always
  returning. It is unchecked whether a switch without an or-pattern does the same.
- **Workaround:** drop the trailing statement.
- **Status:** open.

### Two `@:wire` typedefs of the same shape fail with "Body typing contexts must be left in stack order"

- **Symptom:** `Body typing contexts must be left in stack order`, no file or line, while compiling any project that
  loads the protocol file.
- **Repro:** `@:wire typedef A = {@:id(1) var folders:Array<String>;}` and `@:wire typedef B = {@:id(1) var folders:Array<String>;}`
  as the request and reply of one `RpcMethod<A, B>`. Giving B a second field avoids it.
- **Found:** 2026-10-31, M19 Phase 5 (`WorkspaceFoldersProtocol`). Took ten builds to find, since the message names nothing.
- **Workaround:** make the two shapes differ.
- **Status:** open. The message should name the declaration being typed.

### Declaring a local function ends null narrowing for earlier locals

- **Symptom:** a local that was null-checked before a `function` declaration later in the same function loses its
  narrowing after it.
- **Found:** `mutationDiscovery` in `ScmGitTestMain`. There is no minimal repro yet.
- **Workaround:** copy the local into a new one after the declaration, or declare the function first.
- **Status:** open.

### A function type ending in a parenthesised function type does not parse

- **Symptom:** `E0002: Expected Arrow, got Greater` at the closing `>`.
- **Repro:** `var binding:Null<A->B->(Void->Void)>;` fails with `Expected Arrow, got Greater`, and
  `typedef T = A->B->(Void->Void);` with `Expected Arrow, got Semicolon`. Stock Haxe accepts both. The parser seems to
  read `(Void->Void)` as the argument list of a new-style `(args)->Ret` type.
- **Found:** 2026-10-31, M19 Phase 6 (`WorkspaceRpcServer`).
- **Workaround:** name the inner function type: `typedef CatalogCleanup = Void->Void;` and then
  `A->B->CatalogCleanup`.
- **Status:** open.

### MessagePack cannot encode an anonymous structure type

- **Symptom:** `E1024: MessagePack does not support type TAnonymous {folders,name,scratch}`.
- **Shape:** `MessagePack.encode(value)` where `value` is a plain `typedef` of fields without `@:wire` and `@:id`.
  Stock Haxe has no MessagePack, so this is a limit of haxeon's, not a divergence; the message could say to add
  `@:wire`.
- **Found:** 2026-10-31, M19 Phase 6 (`WorkspaceCatalogService`).
- **Workaround:** fingerprint the fields as joined strings, or mark the typedef `@:wire` with `@:id`s.
- **Status:** open (message only).

### A String made from MessagePack bytes fails at run time

- **Symptom:** `HashLink String cannot contain NUL; use Bytes for binary data`, thrown by `Bytes.toString()` on encoded
  MessagePack. It is deliberate, but nothing at compile time says that `toString()` is unsafe for binary data.
- **Found:** 2026-10-31, M19 Phase 6 (`WorkspaceCatalogService` compared encoded items as strings).
- **Workaround:** `WorkspaceCatalogService.hex` turns the bytes into hex digits.
- **Status:** open.

### A default parameter value from an `inline final` without a type is unresolved

- **Symptom:** `E1020: Unresolved inferred type` at `function refresh(minAge = REFRESH_SECONDS)` where
  `static inline final REFRESH_SECONDS = 0.1;`. Stock Haxe infers `Float`.
- **Found:** 2026-10-31, M19 Phase 6 review fixes (`WorkspaceCatalogService`).
- **Workaround:** type the parameter (`minAge:Float = 0.1`).
- **Status:** open.

### A cast null in an anonymous structure literal fails CFG generation

- **Symptom:** `CFG generation failed for ...resumeFrom: Uncoerced null literal typed as TNull`.
- **Shape:** `var start = {since: -1, plan: (null : Null<CatalogPlan>)};` (an inferred anonymous structure).
- **Found:** 2026-10-31, M19 Phase 6 review fixes.
- **Workaround:** declare a typedef and type the variable (`var start:CatalogResume = {..., plan: null}`).
- **Status:** open.

### Stack trace names the last line of the function, not the failing statement

- **Symptom:** an uncaught `Array index out of bounds` in `AgentContentStorageTest.run` is reported at
  `AgentContentStorageTest.hx:61`, the closing brace area of the function. The failing statement is
  `Sys.args()[0]` on line 12 (the test was started without its directory argument).
- **Same in:** `PersistenceTestMain.main` (reported at 347, failing line 188) and `ActiveContextTestMain`.
- **Effect:** three suites looked broken for a day; it was only a missing argument.
- **Status:** open. A stack trace should name the line of the faulting access.

### E1005 blames a closure for a local that no closure assigns

- **Symptom:** `E1005: Field "detectGeneration" requires an object: "state" is assigned by a closure, so a call that may run an escaped closure clears its null check.` at `ScmService.discover`, after haxeon `a6ac2ba9` ("Track the effects of fresh object construction"). Stock Haxe accepts the code, and haxeon before `a6ac2ba9` did too.
- **Shape:** `var state = roots.get(key); if (state == null) { state = new ScmRootState(key); roots.set(key, state); }
  if (state.detectJob != null) state.detectJob.cancel(); state.detectGeneration = nextGeneration++;`, and a closure
  declared later that reads `state` and assigns its fields (`state.detectJob = null`). `state` is only assigned outside
  the closure, so "assigned by a closure" is wrong; the closure assigns fields of the object, not the local. The
  constructor of `ScmRootState` is impure (field initializers), which `a6ac2ba9` now treats as an unknown call.
- **Repro:** none yet. A reduced version (a `State` class with a `Null<Job>` field, an impure constructor, a closure
  that reads `state` and assigns `state.job`) compiles without error, so the trigger is something else in
  `ScmRootState` (many initialized fields) or in the surrounding method.
- **Found:** 2026-10-31, building the M19 stack against haxeon `1fd91b54`.
- **Workaround:** build the local without reassigning it (`var known = roots.get(key); var state = known != null ? known : new ScmRootState(key);`).
- **Update 2026-11-11:** the same error fires for any closure-assigned local (`value -> x = value`) whose field is read after a call; tests/scm-git needed `var copy = x.value;` at every such site. Reading a field in the same expression as the null check does not trip it.
- **Status:** open. The message should say which call cleared the check, and not claim that a closure assigns a local
  it only reads. Related to the "Unclear" entry on closure-assigned locals below.

### `Reflect.setField` on a struct-valued field crashes with an access violation

- **Symptom:** `Uncaught exception: Access violation` at `Reflect.reflectSetField`, on the first `Color` field.
- **Shape:** `for (field in Reflect.fields(from)) Reflect.setField(to, field, Reflect.field(from, field));` where the
  class has `haxeon.ui.Color` fields (`ThemeTokens`; `Color` is a `struct` since haxeon `30f034c5`). Valid in stock Haxe.
- **Found:** 2026-10-31, moving exosuit to haxeon `8b953dd0` (`ExosuitPalette.theme(dark, target)`).
- **Workaround:** copy the fields by name (`ExosuitPalette.copyTokens`).
- **Cause:** not investigated; presumably the boxed struct from `Reflect.field` is stored into the inline field
  without unboxing.
- **Status:** open.

### Nested `Map<String, Map<String, Array<String>>>` misbehaved in a store: lookups failed, once an access violation

- **Symptom:** in `MachineDeviceStore` (exohost), a `Map<String, Map<String, Array<String>>>` filled and read back
  inside one process gave wrong answers (a grant set just stored was not found) and, intermittently, `Access violation`
  in the unit test run. Not isolated to a small reproduction; the same logic over an `Array<{device, workspace, grants}>`
  passed every run.
- **Found:** 2026-11-03, M19 Phase 9.
- **Workaround:** a flat array of records (`DeviceWorkspaceGrant`).
- **Status:** open, **unconfirmed**: no minimal reproduction yet, so it may have been a mistake in the store that the
  rewrite happened to remove. Worth a small test of nested map values (`map.get(a).set(b, array)`) before relying on it.

### `Map<String, T>.get(null)` is an access violation, not a null-access error

- **Symptom:** `exosuit: frame: Access violation`, with the stack only at the outermost `BuildContext.withScopeUnder`
  rethrow; the real site was `sources.get(view.openWorkspace)` in `WorkbenchPanel.syncState` with `openWorkspace`
  null (a window on no workspace yet, with other workspaces' rows in the map). The `Null<String>` key type-checks.
- **Found:** 2026-11-16, ws_open GUI scenario on entropy-1115.
- **Workaround:** check the key for null before `get`/`exists`.
- **Status:** open. The typer could reject a `Null<String>` key, or the map raise a catchable null error. The
  rethrow in `withScopeUnder` (`throw error`) also drops the original stack, which made this hard to find.

### A conditional over two `Null<Color>` values reports "Type mismatch for conditional branch"

- **Symptom:** `E1003: Type mismatch for conditional branch` at `label.layout.setColor(highlighted ? activeColor : color)`
  with both locals `Null<Color>`.
- **Found:** 2026-10-31, `EditorGutter`, after `30f034c5` (`setColor` takes a non-null `Color`).
- **Workaround:** `var target = highlighted ? activeColor : color; if (target != null) label.layout.setColor(target);`
- **Status:** open. The rejection is right (`Null<Color>` is not a `Color`), but the message blames the branches. It
  should name the argument mismatch.

### Every live patch was rejected: a packed type hashed differently from HashLink

- **Symptom:** every live edit fell back to a full module reload, also the first one after a fresh start:
  `HashLink rejected the patch transaction (status 4): Patch symbol prefix hash does not match module`. The reload
  recreates the app's window, which then moved, lost its size and opened behind other windows.
- **Found:** 2026-11-01, daily use of the editor in live mode.
- **Cause:** `HlPatchWriter.hashTypes` hashed a `Parameterized(Packed, p)` type's kind and parameter, while
  `hash_type_prefix` in `vendor/hashlink/src/hlpatch.c` hashes only the kind of an `HPACKED` type (parameters only for
  `HREF`/`HNULL`). It began once the editor's module had packed field types (value-struct fields; the live module had
  12), probably with upstream `86f7d0b1` "Convert UI data records to value structs" (not bisected).
- **Status:** fixed in haxeon `59b9c786` (cherry-picked from `bb576ede`): a packed type's kind only. Regression test
  `HotReloadMain.testPackedTypeInPrefix`. The runtime is unchanged.

### A resumed live build fails on a lambda whose captures changed: "Unknown IR object $lambda-env"

- **Symptom:** after the minimap fix (`bb6d77ed`, which changes what `EditorPane.build`'s `container.onResolved` closure
  captures), every live rebuild (`scripts/run.py --live`) failed:
  `resuming the published live module ...` then
  `HashLink lowering failed for $lambda:ui.EditorPane.build:build#onResolved(0)@2CCE83B3#1: Unknown IR object "$lambda-env:ui.EditorPane.build:build#onResolved(0)@2CCE83B3#1"`,
  and haxeon kept the old app open. A full build of the same tree passes.
- **Found:** 2026-11-11, the user's live session.
- **Repro:** publish a live module where a closure captures `x`, edit it to capture `y`, then compile in a compiler resumed
  from the published history (`new Compiler(exportIdentityState())`, what `CompilerSession.resumeLiveModule` does).
  Haxeon test `resumed-capture-change-patch` (`tests/runtime/ResumedCaptureChangePatchMain.hx`).
- **Cause:** a lambda whose captures change is a new function with a new environment. The module keeps the old lambda for
  closures the running app may hold, but its environment object is gone from the program. A resident compiler reuses the old
  lambda's lowered code; a resumed one has only its IR, lowers it again, and lowering knew only the program's objects. A
  deleted capturing lambda failed the same way.
- **Workaround (before the fix):** move `graphical/build/host/live.hl.live.state` aside, so the next live run starts a new
  module instead of resuming.
- **Status:** fixed in haxeon `9cd306a7`: lowering resolves an object the program no longer has to the type the running
  module published, and its fields to their published slots. The resumed build patches; no reload needed. Checked on the
  real case: graphical published before `bb6d77ed`, compiler stopped, then built with it: `resuming the published live
  module`, patch revision 2, 46 functions changed, no reload reasons.
- **Seen again on upstream main** (`ff7e29aac`, 2026-11-17, haxeon port): upstream does not have the fix, and since it
  verifies the whole program before a resumed build lowers it, the same test fails one step earlier:
  `IR verification failed for $lambda:Pane.build:build#onResolved(0)@279E7C81#0: Unknown IR object
  "$lambda-env:Pane.build:build#onResolved(0)@279E7C81#0"`. Fixed again on haxeon `exosuit-upstream` ("Live: a resumed
  session patches an edit that changes what a lambda captures, or deletes it"): lowering verifies only the program's own
  functions, not the frozen ones (retired signatures, dropped lambdas), and resolves their objects to the published types
  as before. `resumed-capture-change-patch` passes, with `added-class-patch`, `lambda-renumber-patch` and
  `LiveKeptCheckMain`.

### The compiler worker reports negative allocation bytes for a large compile

- **Symptom:** `worker allocations: bytes=-2147483648 count=459867574 heap=-2147483648` after the graphical app's
  compile. The driver's own report for the same compile says `compile-bytes=17795267928`.
- **Found:** 2026-11-01, clean Windows build on `daily`.
- **Cause:** `CompilerServer` formats the values with `Math.round`, which returns a 32-bit `Int`, so anything past
  2 GiB clamps to `-2147483648` (`src/compiler/tools/CompilerServer.hx`, the `worker allocations` message).
- **Workaround:** none needed; only the report is wrong.
- **Status:** open. Format with `Math.fround` or as a `Float` instead.

### `if (c) {} else f()` at the end of a switch branch or block parsed as a conditional over an empty object

- **Symptom:** none a program can see. Since haxeon `a631f5b40` (`{}` as a value branch), a statement such as
  `if (skip) {} else count(hits);` that is the last thing in a switch branch or in a block is parsed as the expression
  `Conditional(skip, {}, count(hits))`. A Void is expected there, so it types as Void and runs the same branches, but
  the then-branch builds an empty object and drops it. Where nothing is expected the same text does not type:
  `var run = () -> if (skip) {} else count(hits);` gives `E1003: Conditional branches must have matching types`.
- **Found:** 2026-11-12, review of the pushed stack (`Parser.parseExpressionBranch`).
- **Cause:** those places try an expression first (`tryParseExpression`) and fall back to a statement when it fails.
  Before `a631f5b40` the empty block failed as a value ("Expression block requires a result expression"), which is what
  made the fallback happen.
- **Workaround:** none needed.
- **Status:** fixed in haxeon `04f9823e4` (branch `small-fixes`): the `if` that opens a tried expression refuses `{}`
  as a branch, so the statement form is parsed again. `{}` is still an empty object in `c ? {} : value`, in
  `var o:Dynamic = if (c) {} else {a: 1}` and in an arrow body. Test: `tests/programs/if-empty-block-branch.hx` (it
  guards the shapes; it cannot tell the two parses apart).

### `Std.parseInt("09")` is 0: a leading zero reads as octal

- **Symptom:** a Codex or Pi terminal did not record its conversation whenever the record's time had 08 or 09 in a
  field; `workspace-terminals` failed with "A running codex terminal did not keep its conversation" about one run in
  three. `Std.parseInt("09")` returns 0 and `Std.parseInt("010")` returns 8; stock Haxe on HashLink returns 9 and 10.
- **Found:** 2026-11-14 (`AgentTerminalResume.utc` read `03:09:23` as `03:00:23`).
- **Cause:** the runtime's `__std_parse_int` (`native/runtime/strings.c`) is `strtol(text, NULL, 0)`, base 0, which
  takes a leading `0` as octal; the wasm `stdParseInt` in `stdlib/Std.hx` copies that on purpose. HashLink's own
  `hl_parse_int` reads decimal unless the text starts with `0x`.
- **Workaround:** strip leading zeros before `Std.parseInt` (was `AgentTerminalResume.matchedTime`; that code went on
  2026-11-15, when provider terminals began to report their conversation instead of being matched by time). Other
  exosuit callers that parse zero-padded fields are still exposed.
- **Status:** fixed upstream in haxeon `6320ca672` ("Parse integers as Haxe does: Null<Int>, decimal unless 0x"),
  which the port pin includes; `graphical/src/app/LaunchForwarding.hx` no longer works around it.

## Building haxeon's own tools with haxeon (2026-11-11)

Tried with the haxeon-built compiler (`hl bootstrap/compiler.hl --entry=<main> --root=src --root=stdlib
--sources-file=<all src and stdlib .hx>`). The compiler stops at the first error, so each entry point was retried
after a fix or a throwaway stub. Result on `exosuit-m19` (9e0a4259) plus the fixes below (haxeon branch `hx-only`):

| Entry point | Compiles | Runs | Blocking |
|---|---|---|---|
| `FfiAuditMain` | yes | yes, identical output | none (after the `Process.run` fix) |
| `Main` (test-program compiler) | yes | yes | none |
| `tools.HaxeonCli` | no | - | stock `sys.io.Process` streams, `FileSystem.stat`, `Bytes.toHex`, `File.read`, null safety |
| `compiler.tools.CompilerServer` | no | - | `sys.net.Socket`/`Host`, `File.read`, then the CLI's list |
| `LspMain` | no | - | `Sys.stdin()`, `FileOutput.write(Bytes)`, `haxe.io.FPHelper`, then the CLI's list |
| `build.HaxeonBuild` | no | - | the CLI's list (it shares the build executor) |

### Fixed while trying

- **Quoted object field names did not parse.** `{version: 1, "package": {...}}` failed with `E0002: Expected
  Identifier, got StringLiteral` (`HaxeonCli.buildLiveHost`). Fixed in haxeon `a631f5b40`; test
  `tests/programs/quoted-object-field.hx`.
- **`{}` in a value branch was "Expression block requires a result expression".** `cond ? {} : value`
  (`ProfilerService.execute`). Now an empty object literal; it was always an error there. Same commit; test
  `object-literal-empty-branch.hx`.
- **An unbraced catch body before another `catch` did not parse.** `try f() catch (a:A) throw a catch (_:Dynamic) {}`
  failed with `E0002: Expected Semicolon, got Catch` (`LspProtocol`). Fixed in `f77471d17`; test
  `try-unbraced-catches.hx`.
- **`catch (_)` without a type did not parse** (`E0002: Expected Colon`, `BuildEnvironment`). It now catches any
  value like `catch (_:Dynamic)`; stock Haxe types the variable as `haxe.Exception`. Same commit; test
  `try-untyped-catch.hx`.
- **`sys.io.Process.run` with arguments threw on Windows** ("Process arguments are not yet supported on Windows"), so
  a haxeon-built FFI audit failed to run clang. Fixed in the runtime, `22852dab6` (quotes like the streaming spawn).
  Needs a rebuilt `haxeon_runtime.hdll`.
- **Missing `Path.extension`, `withoutExtension`, `withExtension`, `addTrailingSlash`, `Sys.print`, `File.copy`.**
  Added in `6562434f6`; test `path-extension.hx`.

### Open

- **Rest parameters do not parse.** `static function path(...parts:String)` fails with `E0002: Expected Identifier,
  got Dot`. The only one in haxeon's sources (`HaxeonBuild.path`) now takes an `Array<String>` (`9d986eda2`). Status:
  open; needs parsing and `haxe.Rest`.
- **The stock fallback idiom `@:hlNative(...) function f() return 0;` is rejected** with `E1021: @:hlNative binds
  only an extern function`. `CompilerServer.processId` now uses `Sys.getPid()` under `#if haxeon` (`3986cfbf3`).
  Probably deliberate; listed so nobody re-adds the idiom.
- **`switch` over a class value with only `case _:`** fails with `E1019: Switch requires an Int, String, array, or
  enum value` (`BuildPlanner.project`, rewritten in `3986cfbf3`). Stock Haxe accepts it. Low priority.
- **Null safety in tool code.** `Map.get` returns `Null<T>`, and a null check on a call result
  (`if (f() != null && f().length > 0)`) does not narrow the second call. Stock Haxe accepts both. About 175
  `.get(` calls in `build/`, `tools/`, `project/`, `editor/`, `profiler/`, `compiler/service/` (~18k lines no haxeon
  build has typed yet). Each needs a local, a `??` default or an explicit error. Deliberate in haxeon (see
  "Unclear" below); the work is in the tool sources. Seen at `BuildPlan.hx:92` (fixed), `CompilerClient.hx:323`,
  `Executor.hx:92, 148, 207, 278, 303`.
- **An untyped `cast` needs an expected type** (`E1003: Untyped cast requires an expected type`). Deliberate; noted
  because it rules out bulk `cast` workarounds for the item above.

- **`Std.string` of an array prints `[a, b]`; stock HashLink prints `[a,b]`.** Seen as the only difference between
  Wasm built by a stock-built and a haxeon-built compiler: the code is identical, the debug name section spells
  function types like `Function([Bytes, Array(Bytes)], ...)`. Harmless there; anything that parses or compares such
  strings would differ. Status: open, maybe deliberate.

### Standard library needed by the tools (none of it exists in haxeon's stdlib)

- `sys.net.Socket` and `sys.net.Host` (worker and client: bind, listen, accept, connect, `setTimeout`, `select`,
  `host()`, `input`/`output`). Needs runtime natives; `CompilerServer`, `CompilerClient`, `HldiClient`,
  `ProfileCapture`.
- Stock `sys.io.Process`: `new Process(cmd, args)` with `stdout`/`stderr` as `haxe.io.Input`, `stdin` as
  `haxe.io.Output`, `exitCode(block)`, `kill`, `getPid`. haxeon has `Process.run` (whole-output strings) and the
  nonblocking `ChildProcess`. `ProcessRunner` (the build executor) and `BuildEnvironment` use the stock API; a
  haxeon branch of `ProcessRunner` over `ChildProcess.spawn` (which already takes cwd and environment) is the likely
  route.
- `haxe.io.Input`, `haxe.io.Output`, `haxe.io.Eof`, `haxe.io.Error`; `Sys.stdin()`; `FileOutput.write(Bytes)` and
  `FileOutput` usable as an `Output`; `File.read`/`File.write` streams (`sys.io.FileInput`, `FileSeek`).
- `FileSystem.stat` and `sys.FileStat` (`mode`, `mtime`, `size`, `dev`, `ino`); haxeon has `FileSystem.metadata`
  (size, modified, changed).
- `haxe.Timer` (`stamp`), `haxe.SysTools` (`quoteWinArg`), `haxe.io.FPHelper`, `Bytes.toHex` (listed below too).

## Runtime: hl.exe exits with 0xC0000409 after an uncaught exception (Windows)

- **Seen:** `scripts/test-workspace-terminals.py` stage `history-restore` (and once `contracts`). The Haxe stack of the
  uncaught exception prints, then `hl.exe` exits with 3221226505 (STATUS_STACK_BUFFER_OVERRUN, a fail-fast) instead of
  exit 1, so the failure looks like a crash. The test client holds native terminalkit/sqlite handles and a PTY child.
- **Not the cause of the test failure.** The failure was the product bug fixed in `WorkspaceTerminalManager` (a Windows
  ConPTY clears the visible page on start, erasing the "Shell restarted" separator; it now goes into scrollback). The
  exit code only accompanied that exception: no run with a passing test crashed.
- **Status:** open, not diagnosed further (no minidump taken). If it recurs on a passing run, capture a dump with
  WER LocalDumps for `hl.exe` and look at which native library's `/GS` cookie check fails during teardown.

## Runtime: a Windows pipe listener stops after a client left before it was accepted

- **Seen:** a terminal host that was suspended while a workspace service connected to its pipe and gave up never
  accepted another connection after it was resumed; every later service found it "running but not answering".
- **Cause:** NativeKit's local listener (`vendor/nativekit/src/transport/transport.cpp`, the `ConnectNamedPipe` loop)
  accepts `ERROR_PIPE_CONNECTED` and `ERROR_PIPE_LISTENING` but treats `ERROR_NO_DATA` (the client connected and closed
  before the server called `ConnectNamedPipe`) as a failure: it emits `TransportFailed` for the listener and stops.
- **Workaround:** `NativeRpcHub.listen` takes a `failed` callback for the listener's failure, and the host listens
  again (`TerminalHostMain`, "the pipe stopped accepting connections; it listens again").
- **Status:** open in haxeon; the fix would `DisconnectNamedPipe` on `ERROR_NO_DATA` and loop.

### Calling an optional function field of a structure: "Cannot call non-function field"

- **Symptom:** `E1007: Cannot call non-function field "failed"` for `if (entry.failed != null) entry.failed();` where
  `entry` is `{..., ?failed:Void->Void}` (`NativeRpcHub.onEvent`).
- **Workaround:** read it into a local first: `var failed = entry.failed; if (failed != null) failed();`.
- **Status:** open; stock Haxe accepts the direct call.

## Runtime: the collector does not count large native byte exports

- **Seen:** a process that repeatedly exports a long terminal history (`Emulator.historySnapshot`, up to 16 MiB, and
  its encoded copy) grows by gigabytes: HashLink's heap counters stay under 70 MiB while the process holds 2.7 GiB, so
  no collection starts until other allocation reaches the 64 MB trigger, about a minute later. Measured 2026-11-12 in
  the workspace service (its periodic SQLite history save, since removed).
- **Workaround:** the terminal host, which now writes its last screen (`screen.bin`) every 30 s or more while the
  screen changes, calls `hl.Gc.major()` after a save of 4 MiB or more (`TerminalHostMain.saveScreen`).
- **Status:** open; not reduced to a small repro. A fix would have the runtime count the bytes of large buffers
  towards its collection trigger.

## Standard library gaps

Standard Haxe APIs haxeon's standard library does not have yet. Each one forced a hand-written replacement.

- **No `haxe.io.Bytes.toHex()`, and the error does not say so.** `bytes.toHex()` fails with "E1007: Cannot call method
  on non-object" naming the receiver, even when it is a local typed `Bytes` (seen 2026-11-06 in
  tests/haxeon-rpc RpcCompatibilityTests). Workaround: `[for (i in 0...b.length) StringTools.hex(b.get(i), 2)].join("")`.
- **`Date` has only `now()` and `getTime()`:** no `getFullYear`, `getMonth`, `getDate`, `getHours` and so on.
  The workspace migration (removed 2026-11-15) computed the calendar date from the epoch time by hand.
- **No `DateTools`** (`DateTools.format` and the rest).
- **`Bytes` has no `toHex`:** a hex
  fingerprint is a hand-written loop (`WorkspaceCatalogService.hex`).
- **No fsync / flush-to-disk for ordinary file writes, and no `FileOutput.flush` to disk.** `File.saveBytes` and
  `FileOutput` give no durability. Only `sys.io.AtomicFile` flushes (fsync, or FlushFileBuffers, plus the parent
  directory on POSIX), and it publishes a whole file from memory. The migration's backups therefore go through
  `AtomicFile.createBytes`, one file at a time. There is no directory fsync for a created directory.
- **No `sys.FileSystem.stat`, and no `sys.io.File.read` / `FileInput`** ("E1007: Unknown instance method
  sys.FileSystem.stat", seen 2026-11-11). `FileSystem.metadata(path)` gives the size and a whole-second modification
  time. Workaround: `controller.LiveBuildFeed` tails an append-only file by its size and reads it whole when it grows,
  since it cannot seek.
- **Paths of 260 characters or more are not found on Windows** (`FileSystem.exists` false, the other calls fail; seen
  2026-11-12 with a Claude Code record under a deep folder). `hl.exe` has no long-path-aware manifest and the runtime
  passes paths to the C runtime unchanged. The `\\?\C:\...` form with backslashes only works (checked with the same C
  runtime call, `_wstat32`; forward slashes after the prefix do not). Workaround: `workspace.provider.LongPath.of` turns
  a long drive path into that form before the call (Claude and Codex records). A fix in haxeon would add the manifest
  entry, or the prefix, in the runtime's path conversion.
- **No `sys.io.File.copy`.** Workaround: `File.saveBytes(to, File.getBytes(from))`, which reads the whole file into
  memory. Added in haxeon `6562434f6` (it copies through memory the same way).

## Unclear: bug or deliberate

These are stricter than stock Haxe. Each needs a decision, and a better message if it is deliberate.

- **A closure-assigned local loses its null check across calls (E1005).** A local that a closure assigns is not
  narrowed by an `if (x != null)` across any call, since the call might run the closure. Workaround: copy it into
  a local first. This is sound flow typing, but the error does not say why.
- **After a call that always throws, only `return null;` or `return;` is accepted** as the following statement.
- **A `Null<function>` field must be called through a typed local** (`var f = this.callback; if (f != null) f();`).
- **Parsed JSON cast to a typedef is rejected.** Deliberate: structures are records by design.
- **A `;` after a block inside a block is a parse error** ("E0002: Expected expression", seen 2026-11-12):
  `for (i in 0...5) { try f() catch (_:Dynamic) {}; g(); }` is accepted by stock Haxe and rejected here at the `;`.
  Workaround: put the statements on lines of their own, with no `;` after the `}`.
- **A `Null<Int>` field does not initialise an `Int` local** ("E1002: Type mismatch for local "total"", seen
  2026-11-12 in `RpcTerminalBackend`): `var total:Int = snapshot.total;` with `total:Null<Int>` in a typedef is
  accepted by stock Haxe on HashLink. Workaround: `var total:Int = snapshot.total == null ? 0 : snapshot.total;`.
  The message does not say that nullability is what differs.
- **An `if` with no `else` cannot be a closure's whole body inside a call** ("E0002: Expected Else, got RightParen",
  seen 2026-11-15 in `ExosuitApp` and `WorkbenchPanel`): `f(function(name) if (ok) title = name);` is accepted by
  stock Haxe. Workaround: braces, `f(function(name) { if (ok) title = name; });`.

## Generated helper code names an enum abstract value without its type

`haxeon/src/compiler/types/typing/EnumEqualityGenerator.hx:98` writes `originKind: Helper`. When a program that also
compiles the haxeon compiler (the editor does) declares another enum abstract with a value named `Helper` (`exohost.ExohostKind`
did), the build fails with E1005 "Ambiguous enum abstract value "Helper"". An abstract in another package should not make
an unqualified value inside the compiler's own package ambiguous. Workaround in exosuit: the exohost kind is `HelperProcess`.
Fix in haxeon: qualify the value (`FunctionOriginKind.Helper`), or prefer the abstract of the expected type.

## UIKit: TreeView.focusItem on a restored context

Seen 2026-11-16 with driven input (`m19_group_entry`): a click on a Workbench row that takes the window back to a
context it showed before (a group entered a second time, or the root after a group) leaves no widget with the
keyboard, so Down and Enter do nothing until the next click. The first entry into a context keeps the row focused, and
`exosuit.ui.focus` on the same row afterwards succeeds, so the row is focusable; the request of `TreeView.focusItem` is
dropped. Likely cause: the row build checks `interactionStates` for `Focused` to decide that the request is met, and a
restored context's retained row node still carries that state from when the context was last shown, so the request is
cleared without focusing (`haxeon/packages/ui/haxe/haxeon/ui/widgets/collections/TreeView.hx`, the row build
callback). Fix in haxeon: treat the request as met only when `focus.focusedId` is the row's id. No workaround in
exosuit; the scenario clicks the root's row once more before using the keyboard.
