# Haxeon compiler bugs

Bugs in the haxeon compiler that we hit while working on exosuit, with what we know about each. Add every one you
find, even when you work around it, so there is a record. A behaviour that may be deliberate (haxeon is stricter
than stock Haxe in places) is listed under "Unclear" until someone decides.

Each entry: the symptom (the exact error), a minimal repro if we have one, what we think causes it, the workaround,
and the status.

## Open

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

## Standard library gaps

Standard Haxe APIs haxeon's standard library does not have yet. Each one forced a hand-written replacement.

- **`Date` has only `now()` and `getTime()`:** no `getFullYear`, `getMonth`, `getDate`, `getHours` and so on.
  `AgentWorkspaceMigration.timestamp` computes the calendar date from the epoch time by hand.
- **No `DateTools`** (`DateTools.format` and the rest).

- **No fsync / flush-to-disk for ordinary file writes, and no `FileOutput.flush` to disk.** `File.saveBytes` and
  `FileOutput` give no durability. Only `sys.io.AtomicFile` flushes (fsync, or FlushFileBuffers, plus the parent
  directory on POSIX), and it publishes a whole file from memory. The migration's backups therefore go through
  `AtomicFile.createBytes`, one file at a time. There is no directory fsync for a created directory.
- **No `sys.io.File.copy`.** Workaround: `File.saveBytes(to, File.getBytes(from))`, which reads the whole file into
  memory.
## Unclear: bug or deliberate

These are stricter than stock Haxe. Each needs a decision, and a better message if it is deliberate.

- **A closure-assigned local loses its null check across calls (E1005).** A local that a closure assigns is not
  narrowed by an `if (x != null)` across any call, since the call might run the closure. Workaround: copy it into
  a local first. This is sound flow typing, but the error does not say why.
- **After a call that always throws, only `return null;` or `return;` is accepted** as the following statement.
- **A `Null<function>` field must be called through a typed local** (`var f = this.callback; if (f != null) f();`).
- **Parsed JSON cast to a typedef is rejected.** Deliberate: structures are records by design.
