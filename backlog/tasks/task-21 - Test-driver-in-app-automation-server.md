---
id: TASK-21
title: 'Test driver: in-app automation server'
status: Done
assignee:
  - '@codex'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-06 02:28'
labels:
  - testing
milestone: m-2
dependencies:
  - TASK-19
  - TASK-20
priority: high
ordinal: 21000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Automation endpoint compiled into dev/test builds (and enabled only by flag): JSON-RPC over a Unix domain socket or Windows named pipe. Methods: inspect (semantic tree), click/ctrl_click/double_click/drag by element id or coordinates, key, type, scroll, terminal_text(target), wait_for(condition, timeout), get_logs, quit. Input is injected at the platform event layer so it travels the real input path, never bypassing the UI.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Server is disabled in every build unless explicitly enabled, and remains local-only
- [x] #2 click(id) resolves element bounds and injects real mouse events through the input router
- [x] #3 key and type travel the same code path as physical keyboard and committed-text events
- [x] #4 terminal_text returns visible text for a named terminal; TASK-32 extends the resolver and coverage to the scratchpad when it exists
- [x] #5 wait_for supports element-state and terminal-text conditions with timeout
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Freeze a bounded newline-delimited JSON-RPC 2.0 contract. The explicit --test-driver=<endpoint> flag is the only enablement in every build mode. IDs use ui.Id.parse. The first named terminal target is active; TASK-32 extends the same resolver with scratchpad. screenshot is reserved for TASK-22 and returns method-unavailable until then.
2. In testdriver.zig, implement allocation-bounded request parsing, typed method parameters, deterministic JSON responses/errors, FIFO request/response queues, wait conditions/deadlines and unit tests. The protocol never asserts and never logs request payloads.
3. In term.zig, add deterministic visible-viewport UTF-8 serialization that trims trailing blank cells per row, preserves internal blanks/newlines and grapheme tails, and skips wide spacer cells.
4. Behind platform, implement local-only Unix socket and Windows named-pipe transport, private endpoint permissions, bounded frames/queues, clean listener shutdown, named-key/pointer/text injection and an event-loop wake/barrier. Blocking IPC remains off the UI thread.
5. In main.zig, add the explicit endpoint flag and server lifecycle; execute requests FIFO on the main thread; inspect the semantic Tree; resolve element centers; enqueue SDL-equivalent click/key/type/scroll input followed by a barrier; expose active terminal text/log tail; keep wait_for pending without blocking and include its deadline in the loop budget. Route committed text to focused Input or terminal through the same application path.
6. Add protocol/security/unit coverage and a real hidden-window Unix-socket self-check for inspect, click, key/type, terminal_text, wait success/timeout and quit. Format, build, run all tests and headless checks, inspect relevant visual output, update documentation and finalize only against evidence.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-06 scope correction approved by the user: TASK-21 implements the named active terminal now and reserves the scratchpad target for TASK-32, because workspace/scratchpad ownership does not exist until M3. Initial v1 wire contract: newline-delimited JSON-RPC 2.0; one bounded request object per line; opaque canonical ui.Id strings; point parameters use logical window pixels; key chord strings use CTRL/ALT/SHIFT/SUPER plus one named key or Unicode scalar; type uses SDL committed-text events; terminal target active; wait conditions are element exists/hovered/focused/pressed equals boolean or terminal-text contains; screenshots return a defined unavailable error until TASK-22.

2026-10-06 implementation and evidence:
- Protocol core: bounded newline-delimited JSON-RPC 2.0 parser/encoder, typed parameters for all methods, canonical ui.Id parsing, 1 MiB requests, 4 MiB responses, depth/coordinate/timeout bounds, 64-entry queues, deterministic errors, screenshot reserved as unavailable.
- Platform: runtime-reserved SDL wake/barrier events; named-key, pointer, wheel and text injection; private 0600 AF_UNIX endpoints with inode-safe cleanup; protected Windows named pipes restricted to TokenLogonSid with D:P(A;;GRGW;;;<sid>), first-instance and remote-client rejection; clean worker cancellation.
- App: explicit --test-driver endpoint is the sole enablement gate in every build; main-thread FIFO execution; semantic inspect/element-center targeting; input replies after SDL barriers; active terminal visible-text serialization; allocation-free terminal wait matching; in-memory bounded log tail; timeout-aware waits; orderly quit.
- Real hidden-window --driver-test completed 12/12 exchanges for inspect, click, element wait, focused key/type, terminal_text, terminal wait, timeout, logs, screenshot-unavailable and quit. All eight Linux headless checks passed concurrently.
- Verification: zig fmt clean; zig build passed; zig build test --summary all passed 350/357 with seven existing platform skips; platform persistent two-request regression passed. Windows-msvc cross-build was blocked before Conduit by the missing host MSVC CRT/library sysroot. x86_64-windows-gnu analyzed Conduit/Win32 sources through final link, then failed on pre-existing native Ghostty object-format inputs (targets.o, abort.o, simdutf.o). Native Windows pipe runtime coverage remains for the Windows CI runner; no Windows runtime claim is made.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Implemented the in-app automation server end to end. Conduit now exposes a bounded local JSON-RPC endpoint only under the explicit --test-driver flag, uses private Unix sockets or logon-SID-protected Windows named pipes, executes requests on the main thread, and injects click/key/type/scroll through SDL with FIFO barrier acknowledgements. inspect reads the semantic tree; terminal_text and wait_for cover the active terminal; waits time out without sleeps; logs come from a bounded in-memory tail; screenshot remains deliberately unavailable for TASK-22. The deterministic hidden-window driver check passes all 12 exchanges, zig build passes, and 350/357 tests pass with seven existing platform skips. Native Windows runtime validation remains CI-only and was not claimed locally.
<!-- SECTION:FINAL_SUMMARY:END -->
