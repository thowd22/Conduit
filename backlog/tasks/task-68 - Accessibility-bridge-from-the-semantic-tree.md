---
id: TASK-68
title: Accessibility bridge from the semantic tree
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-08 00:07'
labels:
  - accessibility
milestone: m-8
dependencies:
  - TASK-19
priority: low
ordinal: 68000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Expose the semantic element tree to platform accessibility APIs (AT-SPI, NSAccessibility, UI Automation) so screen readers can navigate the sidebar, palette and views.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Sidebar, palette and settings elements are exposed with roles and labels on at least one platform
- [x] #2 Plan for the remaining platforms is documented
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Linux AT-SPI2 provider: src/accessibility.zig speaks D-Bus (minimal wire protocol in Zig, no new dependency) to the a11y bus (org.a11y.Bus GetAddress on the session bus), registers the application with the registry and exposes the semantic tree as Accessible/Component/Action objects with roles (frame, panel, list item, push button, text, entry) and labels, mirroring ui.Tree after each frame on a worker through a snapshot.
2. Verified by a Zig test client talking to a private dbus-daemon session bus started by the test (skipped where dbus-daemon is absent), reading the tree and asserting sidebar, palette and settings roles/labels.
3. docs/accessibility.md: what is exposed, how to test with accerciser/orca, and the plan for NSAccessibility and UI Automation.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Module landed (a84e3f7, ca03cef rebased onto main as 9394ecc): src/accessibility.zig + accessibility/{dbus,snapshot,atspi}.zig, no C dependency; worker thread serves the semantic-tree snapshot over AT-SPI2 (Accessible/Component/Action/Application/Cache, role mapping, state and property signals from diffs), requests back to the owner through a bounded queue; build.zig module; docs/accessibility.md with the macOS/Windows plan. 25 unit tests + private dbus-daemon integration test with a fake registry; opt-in real-stack probe (CONDUIT_A11Y_PROBE) passed against at-spi2-core/libatspi in an ubuntu:26.04 container. Pending for AC1: the three-call main.zig wiring (publish after endFrame, drainRequests on the loop, init with the session bus address) once TASK-60/66 frees main.zig, plus an accessibility.enabled config key; no real screen reader was available.
<!-- SECTION:NOTES:END -->
