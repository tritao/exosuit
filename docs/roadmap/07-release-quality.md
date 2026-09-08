# M7 — Release qualification

Depends on M6. Earlier tasks collect evidence continuously; this stage closes
remaining reliability, portability and distribution gaps.

## M7.1 — Performance and endurance

- [x] Benchmark startup, time to first usable document, typing latency, idle CPU,
  scroll frames, memory, index/search cancellation and plugin reload cycles.
- [x] Use recorded hardware and fixed fixtures: small source file, 10 MB text,
  a very long line and a 10,000-file project. Record unsupported size limits.
- [x] Establish measured budgets before tuning. Initial local target: scheduling
  batches below 8 ms and p95 key-to-frame below 50 ms on the recorded machine;
  report deviations honestly and distinguish rendering from event-loop timing.
- [x] Remove unconditional expensive idle work; profile before changing storage
  or renderer architecture. Soak open/edit/save/close and repeated reload paths.

Acceptance: reproducible measurements and no unexplained resource growth or
progressive latency; all fixes retain file-safety and compiler regression gates.

## M7.2 — Input and platform coverage

- [ ] Implement/verify IME composition distinct from committed text, composition
  placement, font fallback, non-ASCII filenames and DPI transitions.
- [x] Verify OS key modifiers, clipboard, window lifecycle, file replacement and
  user directories on supported platforms. Begin with Linux; track Windows/macOS
  independently and claim support only with build and execution evidence.
- [x] Exercise keyboard focus, readable contrast and essential navigation without
  a mouse. Record accessibility limitations and follow-on requirements.

Acceptance: manual matrix includes composition, combining text, emoji, mixed
scripts, scaling and external file changes. Unavailable platforms stay pending.

## M7.3 — Packaging and CI

- [x] Pin or explicitly record compiler/runtime and renderer dependency revisions;
  eliminate reliance on arbitrary mutable sibling checkouts for release builds.
- [x] Package executable, native modules, fonts, licenses and defaults with robust
  resource lookup outside the working directory. Respect platform user state paths.
- [x] Automate native/headless tests, graphical compile and compiler compatibility
  checks when affected. Keep generated outputs out of source control.
- [x] Document clean setup, launch, configuration, recovery, plugins, known limits
  and the supported platform matrix. Produce a local release artifact; publication
  requires separate authorization.

Acceptance: unpack and launch in a fresh temporary location with no source-tree
resource dependency; complete the M0 smoke route and M6 development route.
Exit: all promised-platform checks pass and open limitations are explicit.
