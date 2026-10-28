# UI exploration implementation checkpoint

All application changes are on `ui-exploration` in its isolated worktree. Reference repositories were cloned beneath ignored `.local/references` and read from disk; no reference dependencies were installed or reference applications executed. Build dependencies and outputs are local to this worktree.

## Delivered behavior

- Coordinated light/dark palettes, compact quiet chrome, selected-tab hierarchy, project-relative breadcrumbs, an inset workspace edge and native contact shadow.
- Application styles survive UI initialization and theme switching. A live-context regression checks this rather than relying only on standalone stylesheet resolution.
- Sessions have a composed header, workspace navigation, a centered reading measure, a crisp outlined multiline composer, model/effort controls, readable roles, exact message/code copy, and preserved provider controls.
- Native Markdown adds quotes, tables and explicit workspace file links; code blocks retain source, syntax and horizontal scrolling. HTML/XML/CSS and additional language aliases select the matching syntax where registered.
- Real inline diffs have line numbers, selectable source, red/green change backgrounds, collapsible files and a bounded two-axis viewport. Compact changed-file summaries expose authoritative paths and counts before details are opened. Counts refer to the retained patch, not net repository checkpoints.
- Optional Codex file metadata identifies bounded slices of the existing diff payload. Existing fields and legacy wire decoding remain supported. Claude's snapshot now explicitly names its wire array type to preserve encoding after this additive schema extension.
- Standalone local PNG/JPEG/GIF image references offer opt-in native preview, dimension/file validation, fit without upscaling, alt text and navigation. Unsupported locations retain an explanatory fallback. This is output preview, not attachment input.
- Completed HTML/SVG and large code fences become compact source cards with exact-copy and disclosure. Native SVG previews render a bounded subset of shapes and paths; unsupported content visibly retains source. HTML stays source-only.
- The composer can include bounded workspace text snapshots through local or remote file services. Codex additionally negotiates image uploads: 32 KiB chunks, two images per draft, 2 MiB per image, private host staging and opaque session-scoped IDs. Images can be sent without synthetic prompt text. Native history reports attached-image counts without exposing staging paths.
- Image leases survive provider restarts and protect in-flight shared-daemon inputs. A private journal and exclusive lock scope storage to the workspace/state identity, bound storage across restarts, and reconcile terminal sessions before deleting pinned inputs. Unresolved leases remain counted against quota.
- New worktree creates a separate Git branch/checkout and starts an integrated session in a new group bound to its directory. Partial failures retain and report the created destination. GitHub actions query the actual origin on the host, revalidate on activation and open the repository or current-branch PR creation page; they do not push or submit a PR.
- Transcript follow-tail respects a reader's scrolled position, with Jump to latest. Draft acknowledgement, approvals, stop, recovery, model selection, Pi queue/steer and read-only/disconnected states retain their behavior.

## Validation performed

The final agent and graphical build passed under the required Windows crash-dialog guard. The final combined native acceptance fixture passed:

- 96 button theme/state combinations, contrast, focus and live application-style persistence.
- Sidebar order/visibility/width, narrow clipping and selected-tab reveal.
- Status layout, responsive priorities and reachable actions in both themes.
- Markdown spacing, code-header geometry, quotes/tables, links, native diff layout/navigation, image parsing and image-header validation.
- Structured file association, bounded patch slices, truncation and legacy MessagePack compatibility.
- Sessions at 320, 420 and 1000 logical pixels in both themes, plus Claude/Pi input, keyboard submission, acknowledgements, model/permissions/approval/stop actions, queue/steer, connection restrictions and transcript scrolling.
- Pure host-independent path/location/scheme and streaming/source-fidelity checks.

Evidence logs live under ignored `.local`: `app-agent-final-build.log`, `acceptance-tests.log`, and `acceptance-links.log`. Tests use fake agent services; they do not constitute real inference acceptance. The clipboard action is checked for accessibility and exact-source wiring without overwriting the user's clipboard. Linux Xvfb integration scenarios were not run on this Windows host.

The subsequent rich-input/workflow checkpoint also passed a full matching app/agent build (`rich-session-app-agent-build-verified.log`). Its current-source checks include:

- `recheck-composite-test.log`: theme/layout, artifact/SVG/diff projection and session controls, including image/text context, image-only submission, delayed acknowledgement and workspace workflow actions.
- `image-staging-final-test.log` and `image-integration-test.log`: relay-sized chunks, legacy capability absence, session scope, offsets, format/size rejection, private lease restart/reconciliation, missing unpinned-file recovery, RPC authorization and image-count/path-redaction projection.
- `recheck-git-test.log`: actual isolated Git worktree creation, invalid/existing branch and directory rejection, with the original checkout's HEAD preserved.
- `recheck-rpc-test.log`: wire compatibility, source authority, operation replay/idempotency and authoritative GitHub origin metadata.
- `renderer-link-regression.log`: path/URI handling, streaming/source fidelity and malformed-hunk counter bounds.

Native capture and tests use their own fixture state and repositories. The complete Linux-oriented provider process harness was not executed on Windows; the changed authorization and conversation portions were run through the native integration subset. No real Codex/Claude/Pi inference, OS image clipboard, actual browser-opening action or PR submission was exercised.

Real native captures were serialized through the existing GUI mutex/guard, with isolated fixture/state and no physical mouse input. Verified copies use unique filenames under `.local/ui-review`, including `ide-dark.png`, `ide-light.png`, `chat-dark-wide-centered.png`, `chat-dark-narrow-centered.png`, `chat-rich-summary-centered.png`, `chat-rich-expanded.png`, `chat-rich-image.png`, and the two `chat-*-model-menu.png` images. The later artifact/SVG and workflow captures cover source disclosure, real SVG geometry, both themes, and a 420-pixel panel with all workflow controls and image/text draft rows visible (`artifact-*.png`, `svg-*-rendered.png`, `workflow-*-narrow.png`). The fixture is intentionally small and does not represent every populated-project layout.

## Remaining product scope

Remaining capabilities include native image clipboard input, persisted attachment thumbnails, Claude/Pi image adapters and durable queued attachments, full HTML/SVG rendering beyond the inert SVG subset, and authenticated PR submission beyond opening its creation page. These are specified in [the Sessions spec](sessions-ui-spec.md) and grounded in [the reference renderer contracts](renderer-contracts.md). The current implementation does not advertise those capabilities.
