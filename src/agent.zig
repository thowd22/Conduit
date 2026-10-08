//! The coding agents Conduit manages, and the boundary around them.
//!
//! `agent` owns the common adapter interface — detect, launch, attach,
//! observe state, send input, answer permission requests, read and write the
//! prompt where supported, stop — the typed event stream every adapter
//! produces, the agent state model, the registry of agents per workspace, the
//! harness-neutral PTY heuristics, and (from TASK-53 on) the harness adapters.
//! Nothing outside this module may special-case a harness (P11, invariant 9),
//! and no transcript, prompt or permission text may trigger an action without
//! an explicit user gesture (§11). An agent never owns, targets or observes
//! the scratchpad (P9, invariant 7); its own PTYs are `agent_terminal`
//! sessions spawned through the workspace's ExecutionContext (P7), which is
//! why `Adapter.launch` describes a process instead of starting one.
//! decision-7 records the strategy: the TUI always runs in a Conduit PTY, an
//! adapter adds the harness's structured side channel, and PTY heuristics are
//! the baseline every agent has.
//!
//! Layout: `agent/state.zig` (states and the transition table),
//! `agent/event.zig` (events and the bounded hand-over queue),
//! `agent/adapter.zig` (the interface), `agent/registry.zig` (agents per
//! workspace), `agent/heuristics.zig` (the PTY baseline),
//! `agent/harness.zig` (the closed harness set), `agent/fake.zig` (the
//! scripted adapter tests use) and `agent/sink_io.zig` (the harness-neutral
//! IO under the sink channels, Local or through a remote context, TASK-61).
//!
//! It may depend on `config`, `input`, `session`, `theme`, `ui` and
//! `workspace` (`build.zig`); today it imports only `session` and `workspace`,
//! for their identity types and the ExecutionContext capability. It makes no
//! OS calls of its own.
//!
//! Threads and memory are documented per file: adapter IO runs on workers,
//! events cross to the owner thread through `EventQueue`, and the registry and
//! heuristics are owner-thread state. Every allocation takes an explicit
//! allocator and every buffer is bounded.

const state = @import("agent/state.zig");
const event = @import("agent/event.zig");
const adapter = @import("agent/adapter.zig");
const registry = @import("agent/registry.zig");
const heuristics = @import("agent/heuristics.zig");

pub const Harness = @import("agent/harness.zig").Harness;

pub const State = state.State;
pub const Source = state.Source;
pub const canTransition = state.canTransition;
pub const transition = state.transition;

pub const Event = event.Event;
pub const Role = event.Role;
pub const Message = event.Message;
pub const ToolUse = event.ToolUse;
pub const FileReference = event.FileReference;
pub const Decision = event.Decision;
pub const DecisionKind = event.DecisionKind;
pub const PermissionRequest = event.PermissionRequest;
pub const PermissionResolved = event.PermissionResolved;
pub const PermissionOutcome = event.PermissionOutcome;
pub const StatusChange = event.StatusChange;
pub const Subagent = event.Subagent;
pub const Notification = event.Notification;
pub const ExitStatus = event.ExitStatus;
pub const StoredEvent = event.StoredEvent;
pub const EventQueue = event.EventQueue;
pub const truncateUtf8 = event.truncateUtf8;

pub const Adapter = adapter.Adapter;
pub const AdapterError = adapter.Error;
pub const Capabilities = adapter.Capabilities;
pub const CorrelationToken = adapter.CorrelationToken;
pub const correlation_env_name = adapter.correlation_env_name;
pub const DetectRequest = adapter.DetectRequest;
pub const LaunchRequest = adapter.LaunchRequest;
pub const LaunchSpec = adapter.LaunchSpec;
pub const AttachRequest = adapter.AttachRequest;
pub const InstructionSource = adapter.InstructionSource;
pub const InstructionApply = adapter.InstructionApply;
pub const InstructionProfile = adapter.InstructionProfile;

pub const AgentId = registry.AgentId;
pub const Agent = registry.Agent;
pub const Ownership = registry.Ownership;
pub const Binding = registry.Binding;
pub const CreateRequest = registry.CreateRequest;
pub const Applied = registry.Applied;
pub const Registry = registry.Registry;

pub const Heuristics = heuristics.Heuristics;
pub const Observation = heuristics.Observation;

pub const FakeAdapter = @import("agent/fake.zig").FakeAdapter;

/// The harness adapters. Each lives in its own file so the adapter tasks
/// (TASK-53, 54, 55, 78) can land independently; a file that is still a stub
/// exports nothing beyond its tests.
pub const claude_code = @import("agent/claude_code.zig");
pub const codex = @import("agent/codex.zig");
pub const pi = @import("agent/pi.zig");
pub const opencode = @import("agent/opencode.zig");

/// The harness-neutral IO under the sink-based side channels: this machine's
/// files, or a remote workspace's through its ExecutionContext (TASK-61).
pub const sink_io = @import("agent/sink_io.zig");
pub const SinkIo = sink_io.SinkIo;

/// Where `harness` reads its instructions and how a change reaches an agent
/// (TASK-59), as its adapter documents it: the one place outside an adapter
/// that maps a harness to its harness knowledge.
pub fn instructionProfile(harness: Harness) InstructionProfile {
    return switch (harness) {
        .claude_code => claude_code.instruction_profile,
        .codex => codex.instruction_profile,
        .pi => pi.instruction_profile,
        .opencode => opencode.instruction_profile,
    };
}

test {
    _ = @import("agent/harness.zig");
    _ = state;
    _ = event;
    _ = adapter;
    _ = registry;
    _ = heuristics;
    _ = @import("agent/fake.zig");
    _ = claude_code;
    _ = codex;
    _ = pi;
    _ = opencode;
    _ = sink_io;
}
