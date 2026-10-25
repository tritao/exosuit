# Review of patch-freeze.md (key: patch-freeze-verify)

Verdict: **holds**. The main claim (the ~1.9 s freeze is `hash_type_prefix`'s linear string-table scan) was re-read in the code, reproduced, and corroborated by an unprofiled run.

## Checked and confirmed
- Code: `hash_type_string_index` (vendor/hashlink/src/hlpatch.c:371-379) is a linear scan with `ustrlen` per candidate; it is called for every obj/struct name, field, proto, virtual field, enum name/constructor and abstract name in `hash_type_prefix` (:393-436). `hl_module_apply_patch` (:866) calls it on every patch at :872. `hash_type_global_index` (:385-391) is a linear scan too.
- `hl_get_ustring` (src/code.c:133-142) is a cached lazy conversion, so after the first pass the cost is the scan plus `ustrlen` (src/std/ucs2.c:39-43).
- Reproduced under the lock with their harness (outputs in patch-freeze-verify/rerun-linear.txt, rerun-compare.txt): hash types 1,974.8 / 1,961.0 ms, apply 1,977.4 / 1,963.6 ms; 23,287 lookups, 106,293,721 candidates scanned (identical counters). Compare run: indexed build 1.57 ms + hash 5.54 ms -> 2573676373, equal to linear. About 4% slower than their numbers, likely from machine load.
- **New, independent corroboration without any profiler**: merged-live-check/frames/frame-timeline.jsonl has a 1.927 s gap between frame 967 (startedAt 1792962663.550) and frame 968 (1792962665.482), about 16.9 s after the first frame, which matches driver.log "edit 1 applied after 14.5s" at 78.3 s. It is the only gap >1.1 s after startup. So the freeze is not a profiler artifact.
- Harness source = vendor hlpatch.c plus timing/counter additions only (diff --strip-trailing-cr checked); built /O2 and linked against the release objects.
- `git log -S hash_type_string_index` -> 7827a4e 2026-09-05 "Harden live patch decoding and JIT staging".
- Lock: apply happens with runtime->lock held (src/hlruntime.c ~447-454); called from LiveHost.hx:48 on the tick thread.

## Problems / caveats
- Harness patches are synthetic (75-105 bytes, trivial ORet bodies) and their prefix hashes were taken from the VM itself (mkhlp.py --hashes). This does not affect the hash timing (computed before comparison), but hl_patch_read/convert/JIT costs of a real 6.9 MB patch were not measured. The upper bound of ~10 ms is inferred, not measured.
- The 17.7 ns/candidate figure includes instrumentation inside the loop (NULL check and counter per candidate, 2 QPC per lookup). It is a small effect, since the unprofiled editor gap is the same size.
- "Grows with the square of app size" is an inference; the measured fact is O(names × average first-match position).
- Fix 3's premise "patches can only append FUN/ABSTRACT/REF/NULL types" is imprecise. `validate_patch_types` (hlpatch.c:778) rejects only OBJ/VIRTUAL/ENUM/PACKED/out-of-range; primitives, HMETHOD and **HSTRUCT** pass. `stage_patch_types` (:845-864) memsets the type, so an appended HSTRUCT would have obj==NULL, and `hash_type_prefix`'s HOBJ/HSTRUCT case would dereference NULL on the next patch. This is a latent crash, separate from the perf issue. Any incremental-hash cache must handle it, or validation should reject HSTRUCT.

## Missing angles
- A cheaper index exists: names are loaded through `hl_read_ustring`, which returns the cached `code->ustrings[i]` pointer (code.c:144-151, 226, 232), so a pointer->index map works if strings are deduplicated. Content mapping (their prototype) is the safe first-match equivalent.
- The fixes keep the per-call O(module) work (string hash, string recopy, map build, ~5-7 ms). They are fine for now, but fix 3 (incremental) is what removes the size dependence.
