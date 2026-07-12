# Notion Handoff Workflow

This file informs coding agents (Claude Code, Grok, Codex, Cursor) about the Notion second-brain system and how to produce handoff snapshots for the Handoff Librarian agent.

---

## What exists in Notion

- **🐙 GitHub Project Work Tracker** — task/state database for all coding projects. Each row tracks status, current phase, current agent, branch, next action, and a restart brief.
- **📦 Agent Handoff Snapshots** — database that stores structured handoff events. Each snapshot captures who handed off to whom, current state, next objective, blockers, decisions, and a restart brief.
- **Handoff Librarian** — a Notion custom agent that ingests handoff packets and automatically creates snapshots + updates the tracker.

## Your role as a coding agent

You are an execution agent (architecture, implementation, UI, PRs). You are NOT the memory system. When a session ends or a handoff occurs, your job is to produce a **handoff packet** that Kalada can paste to the Handoff Librarian.

Do not try to write to Notion yourself. Do not try to call the Notion API. Just produce the handoff packet as text output and let Kalada deliver it.

---

## When to produce a handoff packet

Produce a handoff packet when:
- Kalada says they are pausing, switching tools, wrapping up, or ending a session
- Kalada explicitly asks for a handoff
- You are being handed off to another agent (Claude → Grok, Grok → Cursor, etc.)
- A significant milestone or architecture decision was reached

Do NOT produce a handoff packet for:
- Trivial commits (typo fixes, formatting)
- Mid-session check-ins
- Every single commit

---

## Handoff packet format

Copy this template and fill it in. Keep every field as short as possible while remaining useful. This is a compressed state object, not a recap.

```
## Handoff
Project: [project name]
Repo: [repo name]
Branch: [current git branch]
From: [your agent name — Claude Code / Grok / Codex / Cursor / Human]
To: [receiving agent name — Claude Code / Grok / Codex / Cursor / Blume / Human]
Commit: [latest commit hash, if available]
Handoff type: [Architecture / Parallel Implement / UI / Visual / PR / CI / Fallback / Overflow / Session Pause / Session End]

## Current state
- [1-3 bullets max. Where things stand right now.]

## Next objective
- [1-2 bullets max. What the next agent or person should do.]

## Blockers / risks
- [1-2 bullets. What stopped progress, if anything. Write "None" if clear.]

## Decisions
- [1-2 bullets. Architecture or design decisions made this session, if any. Write "None" if none.]

## Restart instruction
- [2-3 bullets. Where to look, what to check, what to do first when resuming.]
```

---

## Rules for producing good packets

- **Compress, don't expand.** Every field should be as short as possible.
- **Be specific.** "Check the auth middleware" is better than "continue working on the backend."
- **Include decisions, not just tasks.** If an architecture choice was made, record it — that's the most valuable memory.
- **Don't summarize the whole session.** Only capture what future-Kalada or the next agent needs to resume.
- **Don't include code.** Reference files and branches by name, not by pasting code.
- **Be honest about blockers.** If something is unverified or broken, say so.

---

## Example handoff packet

```
## Handoff
Project: Cleared
Repo: Cleared
Branch: feature/w4-finalization
From: Claude Code
To: Human
Commit: abc123
Handoff type: Session Pause

## Current state
- W4 web finalization changes landed (CORS tightening, care-label styles, recommendation pills, brand gate docs)
- All changes are agent-generated and unverified

## Next objective
- Run the web extension end-to-end
- Verify __NEXT_DATA__ structure and backend image-fetch logs

## Blockers / risks
- No real E2E test run yet — agent changes are unverified

## Decisions
- Approved care-label styles from artifacts/design
- Added recommendation pills (buy, negotiate, skip)
- Added brand gate documentation

## Restart instruction
- Start by running the extension E2E in the browser
- Check docs/ios-to-web/readme.md for full changelog
- Verify __NEXT_DATA__ and backend logs before making further changes
```

---

## What Kalada does with the packet

Kalada pastes the packet to the Handoff Librarian in Notion. The agent then:
1. Creates a snapshot row in Agent Handoff Snapshots
2. Updates the matching tracker row with live state
3. Refreshes the restart brief
4. Links the snapshot to the tracker item

Kalada does not need to manually update the tracker — the Handoff Librarian handles it.

---

## ⚠️ Blume status: unclear for now

Kalada Just downloaded Blume, but their docs are very limited in terms of understanding how to programmatically trigger Blume via CLI hooks. It may not be easy to connect the Notion Worker for this task, but as Kalada continues to use Blume, we can update how this is handled.

---

## Quick reference: agent roles

| Agent | Role |
|------|------|
| Claude Code | Architecture, serial judgment, deep planning |
| Grok | Parallel implementation, worktrees, PR/CI babysit |
| Codex | Quota overflow, bulk mechanical code |
| Cursor | Visual UI/CSS iteration only |
| Blume | Control tower: shared rules, worktree tracking, spend — **now available to Kalada, but limited docs and functionality with grok may limit its use to just CC and Codex until Blume devs release new versions** |
| Git | Zero-token message bus (commit prefixes = handoff signals) |
| Handoff Librarian | Notion memory: snapshots, tracker updates, restart briefs |
