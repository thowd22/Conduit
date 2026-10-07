---
id: TASK-68
title: Accessibility bridge from the semantic tree
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 23:39'
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
- [ ] #2 Plan for the remaining platforms is documented
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Linux AT-SPI2 provider: src/accessibility.zig speaks D-Bus (minimal wire protocol in Zig, no new dependency) to the a11y bus (org.a11y.Bus GetAddress on the session bus), registers the application with the registry and exposes the semantic tree as Accessible/Component/Action objects with roles (frame, panel, list item, push button, text, entry) and labels, mirroring ui.Tree after each frame on a worker through a snapshot.
2. Verified by a Zig test client talking to a private dbus-daemon session bus started by the test (skipped where dbus-daemon is absent), reading the tree and asserting sidebar, palette and settings roles/labels.
3. docs/accessibility.md: what is exposed, how to test with accerciser/orca, and the plan for NSAccessibility and UI Automation.
<!-- SECTION:PLAN:END -->
