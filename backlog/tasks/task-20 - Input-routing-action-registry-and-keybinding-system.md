---
id: TASK-20
title: 'Input routing, action registry and keybinding system'
status: Done
assignee:
  - '@codex'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-06 01:04'
labels:
  - input
milestone: m-2
dependencies:
  - TASK-12
  - TASK-19
modified_files:
  - src/input.zig
  - src/ui.zig
  - src/main.zig
  - src/pty.zig
  - AGENTS.md
priority: high
ordinal: 20000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Central action registry (every command is a named action with optional arguments) and a router that decides whether a key or mouse event goes to app keybindings, a focused UI element, or the terminal. Default keybindings per platform, chords, and a guarantee that unbound keys always reach the terminal.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Actions are registered by name and invocable from keybindings, mouse and the palette
- [x] #2 Default bindings differ appropriately between macOS and Linux/Windows
- [x] #3 Keys not bound by the app are passed to the terminal unmodified
- [x] #4 Unit tests cover binding resolution and chord handling
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add the allocation-free action and binding contracts in input.zig. A fixed-capacity registry retains stable action definitions in registration order: validated name, user-facing label and handler. Invocation carries source (keybinding, mouse or palette), optional originating ui.Id, and borrowed named string arguments. Duplicate/invalid registration and unknown invocation fail explicitly.
2. Define platform-explicit default binding tables for macOS and Linux/Windows, using only shipped clipboard actions. Resolve exact normalized modifiers from the unshifted key identity; lock modifiers do not affect matching and extra intent modifiers do. A bound press invokes once while repeat/release are consumed; an unbound route returns the original translated term.KeyPress unchanged. Preserve the exhaustive Ctrl+C/SIGINT and conditional selection-copy policy.
3. Add narrow ui.Tree accessors for production routing to inspect the focused element/Input without exposing or duplicating the private paint tree. Keep ui activations inert: input/main dispatch them through the registry.
4. Integrate one production router in main.zig with priority app binding, focused UI behavior, then byte-identical terminal fallback. Route mouse and focused keyboard activation through the same registry. Replace direct clipboard branches with registered clipboard actions while preserving terminal selection, middle-click primary paste, terminal mouse capture, IME and multiline Input paste normalization. Convert SDL logical pointer coordinates to the semantic tree device coordinate space.
5. Extend unit coverage for registration/lookup/order/errors, all invocation sources and arguments, both platform tables, unshifted chord resolution, locks/extras, transition consumption, and exact terminal fallback. Extend real SDL --ui-test to use the production router and prove click/Enter dispatch parity and focused Input editing; extend --clipboard-test to prove registry-backed clipboard actions and an unbound key reaching the child unchanged. Coordinator formats, builds, runs all tests and seven Linux headless checks, inspects the screenshot, updates docs and finalizes only against evidence.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-06 preparation: TASK-12 and TASK-19 are Done, so TASK-20 is eligible. TASK-19 returns inert Activation{id, action}; TASK-20 owns dispatch. Optional action arguments use borrowed named string pairs rather than a product-specific typed schema; TASK-31 can collect palette input into those pairs. Palette UI remains TASK-31, but registry invocation explicitly supports a palette source and deterministic enumeration. Only shipped clipboard actions and fixture actions are registered; future feature actions land with their features.

2026-10-06 implementation evidence: the fixed-capacity Registry validates and enumerates named actions and carries keybinding, mouse or palette invocation metadata with optional semantic origin and named arguments. Production click/Enter and clipboard key paths invoke the registry. Platform tables provide Cmd+C/V on macOS and Ctrl+Shift+C/V on Linux/Windows. BindingState and App-owned focused-UI transition state claim before mutation, preserve ownership across repeats/releases and modifier-order changes, and return the exact translated key to the terminal when unbound. Focused Input paste normalizes contiguous CR/LF/tab/U+2028/U+2029 runs to one ASCII space; malformed/control/oversize input is rejected atomically and external clipboard failures remain non-fatal. Ctrl+C without a selection remains SIGINT. A contention audit also fixed the POSIX PTY child boundary so terminal signal dispositions/masks are restored before exec even when Conduit itself starts as a background job. Verification: zig build passed; zig build test passed 320/327 with the 7 existing platform skips; grid, self, scroll, mouse, clipboard, ui and ime headless checks all passed concurrently; two concurrent clipboard checks passed; zig fmt --check, zig build font-check and backlog doctor passed; an aarch64-macos compile-only pty test passed. The 640x360 UI screenshot was inspected for layout, text, selection/cursor and clipping.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Implemented the central named-action registry and three-stage input router. Added platform-specific default clipboard bindings, stateful key ownership, exact terminal fallback, semantic click/keyboard dispatch parity, focused Input editing and normalized multiline paste, plus atomic handling of invalid clipboard content. Hardened POSIX PTY child signal setup so Ctrl+C semantics survive a background-launched parent. All four acceptance criteria are covered by unit and real SDL/PTY evidence.
<!-- SECTION:FINAL_SUMMARY:END -->
