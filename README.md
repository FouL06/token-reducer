# token-reducer

A one-command Mac setup that cuts an AI coding agent's **token usage by ~86–94%** with **no loss
of correctness** — by running a local LLM for cheap work, compressing command output, and keeping
big blobs out of the model's context window. Built for Claude Code; the core works with Codex,
Cursor, Gemini CLI, and other agentic CLIs too.

```bash
git clone git@github.com:FouL06/token-reducer.git
cd token-reducer && ./setup.sh        # check → install missing → verify → ready
./setup.sh check                      # read-only: what's installed vs missing
./uninstall.sh                        # clean revert (config only; keeps your models)
```

Full step-by-step runbook (and the non-Claude-Code adapters): **[SETUP.md](./SETUP.md)**.

### Pick your platform

| Script | Platform | What it sets up |
|---|---|---|
| `setup.sh` | **macOS** (Apple Silicon) | Full Claude Code token stack + Ollama (MLX) |
| `setup-linux.sh` | **Linux** (apt / dnf / pacman, auto-detected) | Same full stack; Ollama via official install.sh + systemd |
| `setup-cachyos-ollama.sh` ⭐ | **CachyOS / Arch + NVIDIA** (e.g. RTX 3060, 6 GB VRAM) | Local coding model stack via **Ollama (CUDA)** with **Tool Calling** + **`rtk` output compression** wired into **Zed**. Fully verified. |
| `uninstall.sh` | macOS / Linux | Tiered revert (config-only by default; `--all` for full teardown) |

**Local coding on Zed + NVIDIA (CachyOS / Arch):** For GPUs with 6 GB VRAM (e.g., RTX 3060 Laptop), `ollama-cuda` installs directly from official CachyOS/Arch repos (`cachyos-extra-v3` / `extra`) and auto-offloads cleanly to CUDA with systemd persistence.
* **Models:** `qwen2.5-coder-tuned` (pinned 8k context) & `qwen2.5-coder:7b` (Q4_K_M ~4.7 GB VRAM) for main coding, and `qwen2.5-coder:3b` (~1.9 GB) for high-speed tasks.
* **Tool Calling:** Native structured function calling is verified and enabled via `"supports_tools": true` in `~/.config/zed/settings.json`.
* **Output Compression:** `rtk` compresses verbose build, test, and git terminal output before it hits your assistant's context.

All scripts accept `check` · `verify` · `--dry-run`. Run `check` first.

---

## The problem

AI coding agents burn tokens on three things that don't need the expensive frontier model:

1. **Verbose command output** — a test run, `pnpm install`, `git diff`, or `kubectl get pods`
   dumps hundreds of lines of mostly-noise straight into the context window.
2. **Big blobs read inline** — whole files, logs, and doc pages get pulled into context to extract
   one fact.
3. **Cheap work on an expensive model** — scanning, summarizing, and fetching are low-judgment but
   run on the same pricey model (and context) as the actual reasoning.

token-reducer attacks all three.

## How it works — three levers (biggest first)

### 1. Subagent isolation — *the dominant lever*
Gather/scan/summarize/fetch work runs in **separate subagent context windows**; only a tight brief
returns to the main window. On a real Next.js + Three.js build, the research phase was **~25K
tokens of docs/reasoning → ~1.4K of briefs (−95%)** — and the code still compiled and passed tests
from the briefs alone. The 11-agent fleet (below) is how this happens.

### 2. Output compression — `rtk`
A Rust proxy that filters verbose command output before it reaches the model (tests, lint, `git`,
`docker`, `kubectl`, `pnpm`, …). Wired as a `PreToolUse` hook, it transparently rewrites
`git status` → `rtk git status`, etc. 80–99% reduction on those commands. A small wrapper
(`rtk-extend.mjs`) widens coverage to tools rtk's default allowlist skips (pnpm, docker, kubectl).
*Compound commands it can't safely rewrite (`$(...)`, pipes, redirects) are routed to context-mode
instead — see below.*

### 3. Local routing — free gather
Cheap gather/verify agents run on a **local Ollama model ($0)** instead of the cloud; only
synthesis and review hit the paid model. `claude-code-router` maps each tagged subagent to the
local model under `ccr code`. Result: ~40% cheaper (cloud-Haiku gather) to ~62% cheaper (local
gather) per session, with local tokens counted as **free** — only what the cloud model used is
charged.

## The tools

| Tool | Role | How it cuts tokens |
|---|---|---|
| **Ollama** (official app + MLX) | Local LLM runtime | Runs `qwen3-coder`/`gpt-oss`/`glm` locally so gather/verify work costs $0 and never touches the cloud context. |
| **rtk** | Output compression (Rust proxy) | Filters/summarizes verbose command output via a Bash hook. Multi-tool (`rtk hook claude\|cursor\|gemini\|copilot`). |
| **context-mode** | Context store (Claude Code plugin) | Sandboxes large tool output into SQLite/FTS5 and serves it back by search instead of dumping it into context. The catch-all for compound commands + big-data processing. |
| **claude-code-router (CCR)** | Per-subagent model routing | Routes tagged gather agents to the free local model while the main loop/reviewer stay on the cloud model. |
| **ccusage** | Spend tracking | Real per-session/all-time cost (used by the SessionEnd economics report). |

## The agent fleet (`~/.claude/agents/`)

Cheap models gather + verify, a stronger model assembles, a reviewer gates:

- **GATHER** (Haiku / local): `scanner` (locate code), `summarizer` (condense files/logs/diffs),
  `doc-retriever` (distill external docs), `extractor` (pull structured fields), `tool-caller`
  (drive web/MCP/shell incl. Linear), `triager` (classify + route inbound work).
- **BUILD** (Sonnet): `planner` (assemble findings into a plan), `writer` (docs).
- **VERIFY**: `verifier` (Haiku — adversarially confirm a cheap-gathered claim), `test-runner`
  (Haiku — run tests/lint/build, return only pass/fail + failures), `reviewer` (Sonnet — gate a
  diff/plan before commit).

Routing rules live in `~/.claude/CLAUDE.md` (`# modelRouting` + `# tokenLanes`). The lane rule:
*simple verbose command → Bash (rtk); compound/piped/processed → `ctx_execute`; whole test/build/
lint run → `test-runner` subagent.*

## What setup.sh installs & wires

Official **Ollama.app** (not Homebrew — the brew bottle lacks the `llama-server` runner) + 3 models
+ a tuned `qwen3-coder-tuned`; **rtk** + the `rtk-extend` hook; **context-mode** plugin; **ccusage**;
**claude-code-router** + config; the **11-agent fleet**; `CLAUDE.md` routing; `settings.json` hooks
(`PreToolUse` rtk, `SessionStart` warm-up, `SessionEnd` economics); a `SessionStart` script that
brings the local stack up and warms the model; and a `SessionEnd` script that logs spend + savings.

It's **idempotent, resumable, non-destructive** (backs up + merges, never clobbers `~/.claude`),
and **never enters your credentials** — the free local stack works with no API key; cloud routing
under `ccr code` needs your Anthropic key (you add it, then `ccr restart`).

## Results & honest caveats

- **−86–94% context tokens on research/exploration**, **100% functional correctness** on real builds (tests + production
  build pass from the distilled briefs), **−40–62% cost**.
- **Verified on CachyOS / Linux (RTX 3060 Laptop):**
  - **Subagent Research & Verification:** −87% to −99% context tokens (planning brief: 85 tokens; review verdict: 3 tokens vs ~1,450 tokens uncompressed).
  - **Command Output Compression (`rtk`):** −43% to −62% on git status, logs, and verbose toolchain commands.
  - **Local Model Footprint:** 4.68 GB / 6.14 GB VRAM on CUDA, <250ms tool call latency.
- **Token reduction ≠ speed.** It trades some latency (subagent round-trips, slower local model)
  for context + cost; the win is fitting more in the window and paying less, plus faster turns on
  long sessions. Local routing specifically trades speed for $0.
- **rtk only sees Bash, and only simple commands.** Compound commands route to context-mode / subagents; that's
  by design, not a gap.
- **Most of the leverage is the subagent/context-mode lanes**, not squeezing rtk.

## Uninstall / recover from a broken state

```bash
./uninstall.sh            # revert CONFIG only (agents, hooks, scripts, settings entries,
                          #   CLAUDE.md blocks, CCR config). Keeps Ollama + models + tools.
./uninstall.sh --models   # also remove the pulled models
./uninstall.sh --all      # full teardown (Ollama.app, rtk, ccr, ccusage, plugin)
./uninstall.sh --restore  # restore newest settings.json/CLAUDE.md backups
./uninstall.sh --dry-run  # preview, change nothing
```
