// Conduit's Pi extension (TASK-55, decision-7). Loaded with `pi -e <path>`.
//
// It only *reports*: every forwarded Pi event becomes one JSON line appended
// to `$CONDUIT_AGENT_SINK/events.jsonl`, tagged with `$CONDUIT_AGENT_TOKEN` so
// Conduit can find the agent. It never receives commands except one bounded
// answer per permission request it raised itself.
//
// Gate (`$CONDUIT_AGENT_GATE` = "1" for bash/write/edit, "all" for every
// tool): a tool call asks `ctx.ui.confirm`, which is Pi's own TUI dialog
// interactively and an `extension_ui_request` in RPC mode. With a sink, the
// request is also written as a `permission_request` line and the extension
// watches `$CONDUIT_AGENT_SINK/decisions/<id>` ("yes" or "no"); whichever
// answers first wins and the dialog is aborted. The watch ends when the
// dialog resolves or the turn is aborted, so it is bounded by the human.
//
// Dependency-free plain JavaScript (Pi loads it through jiti); Node built-ins
// only. Text fields are truncated here so no line grows without bound.

import { appendFileSync, mkdirSync, readFileSync, unlinkSync } from "node:fs";
import { join } from "node:path";

const SINK = process.env.CONDUIT_AGENT_SINK || "";
const TOKEN = process.env.CONDUIT_AGENT_TOKEN || "";
const GATE = process.env.CONDUIT_AGENT_GATE || "";
const TEXT_LIMIT = 4000;
const SUMMARY_LIMIT = 500;
const POLL_MS = 100;
const GATED = new Set(["bash", "write", "edit"]);

let sequence = 0;

function cut(value, limit) {
	if (typeof value !== "string") return "";
	if (value.length <= limit) return value;
	// Cut by code point so a surrogate pair is never split.
	return Array.from(value.slice(0, limit + 1)).slice(0, limit).join("");
}

function emit(type, fields) {
	if (!SINK) return;
	const line = JSON.stringify({ v: 1, token: TOKEN, type, ...fields }) + "\n";
	try {
		appendFileSync(join(SINK, "events.jsonl"), line);
	} catch {
		// Reporting must never break the agent.
	}
}

function textOf(content) {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return content
		.filter((block) => block && block.type === "text" && typeof block.text === "string")
		.map((block) => block.text)
		.join("\n");
}

function thinkingOf(content) {
	if (!Array.isArray(content)) return "";
	return content
		.filter((block) => block && block.type === "thinking" && typeof block.thinking === "string")
		.map((block) => block.thinking)
		.join("\n");
}

function summaryOf(args) {
	if (!args || typeof args !== "object") return "";
	if (typeof args.command === "string") return cut(args.command, SUMMARY_LIMIT);
	if (typeof args.path === "string") return cut(args.path, SUMMARY_LIMIT);
	if (typeof args.pattern === "string") return cut(args.pattern, SUMMARY_LIMIT);
	return "";
}

function pathOf(args) {
	return args && typeof args === "object" && typeof args.path === "string" ? cut(args.path, 4096) : undefined;
}

// Conduit publishes a decision by renaming a complete file into place, so a
// read never sees half of one; anything but "yes" or "no" is left alone.
function readDecision(id) {
	const file = join(SINK, "decisions", id);
	let text;
	try {
		text = readFileSync(file, { encoding: "utf8" }).slice(0, 16).trim();
	} catch {
		return undefined;
	}
	if (text !== "yes" && text !== "no") return undefined;
	try {
		unlinkSync(file);
	} catch {}
	return text === "yes";
}

async function gate(event, ctx) {
	const id = `c${process.pid}-${++sequence}`;
	const title = `Allow ${event.toolName}?`;
	const summary = summaryOf(event.input);
	if (!SINK) {
		if (!ctx.hasUI) return true;
		return ctx.ui.confirm(title, summary);
	}
	try {
		mkdirSync(join(SINK, "decisions"), { recursive: true });
	} catch {}
	emit("permission_request", { id, toolName: event.toolName, toolCallId: event.toolCallId, title, summary });
	const dialog = new AbortController();
	let fromFile;
	let timer;
	const watched = new Promise((resolve) => {
		timer = setInterval(() => {
			if (ctx.signal && ctx.signal.aborted) {
				resolve(false);
				return;
			}
			const answer = readDecision(id);
			if (answer !== undefined) {
				fromFile = answer;
				resolve(answer);
			}
		}, POLL_MS);
	});
	const asked = ctx.hasUI ? ctx.ui.confirm(title, summary, { signal: dialog.signal }) : new Promise(() => {});
	const allowed = await Promise.race([watched, asked]);
	clearInterval(timer);
	if (fromFile !== undefined) dialog.abort();
	emit("permission_resolved", {
		id,
		outcome: allowed ? "allowed" : "rejected",
		by: fromFile !== undefined ? "conduit" : "harness",
	});
	return allowed;
}

export default function (pi) {
	pi.on("session_start", async (event, ctx) => {
		const sm = ctx.sessionManager;
		emit("session_start", {
			reason: event.reason,
			sessionId: sm && sm.getSessionId ? sm.getSessionId() : undefined,
			sessionFile: sm && sm.getSessionFile ? sm.getSessionFile() : undefined,
			cwd: ctx.cwd,
		});
	});
	pi.on("session_shutdown", async (event) => emit("session_shutdown", { reason: event.reason }));
	pi.on("agent_start", async () => emit("agent_start", {}));
	pi.on("agent_end", async (event) => {
		const messages = Array.isArray(event.messages) ? event.messages : [];
		const last = messages.filter((m) => m && m.role === "assistant").pop();
		emit("agent_end", {
			stopReason: last ? last.stopReason : undefined,
			errorMessage: last && last.errorMessage ? cut(last.errorMessage, SUMMARY_LIMIT) : undefined,
		});
	});
	pi.on("message_end", async (event) => {
		const message = event.message;
		if (!message || (message.role !== "user" && message.role !== "assistant")) return;
		const thinking = message.role === "assistant" ? thinkingOf(message.content) : "";
		emit("message_end", {
			role: message.role,
			text: cut(textOf(message.content), TEXT_LIMIT),
			thinking: thinking ? cut(thinking, TEXT_LIMIT) : undefined,
			thinkingCut: thinking.length > TEXT_LIMIT ? true : undefined,
			stopReason: message.stopReason,
		});
	});
	pi.on("tool_execution_start", async (event) =>
		emit("tool_execution_start", {
			toolCallId: event.toolCallId,
			toolName: event.toolName,
			summary: summaryOf(event.args),
			path: pathOf(event.args),
		}),
	);
	pi.on("tool_execution_end", async (event) => {
		const output = textOf(event.result && event.result.content);
		emit("tool_execution_end", {
			toolCallId: event.toolCallId,
			toolName: event.toolName,
			isError: !!event.isError,
			output: cut(output, SUMMARY_LIMIT),
			outputCut: output.length > SUMMARY_LIMIT ? true : undefined,
		});
	});
	if (GATE === "1" || GATE === "all") {
		pi.on("tool_call", async (event, ctx) => {
			if (GATE !== "all" && !GATED.has(event.toolName)) return undefined;
			const allowed = await gate(event, ctx);
			if (!allowed) return { block: true, reason: "Tool call rejected" };
			return undefined;
		});
	}
}
