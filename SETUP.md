# token-reducer — local-LLM + AI-CLI token-reduction stack

> **For the AI agent running this (Claude Code / Codex / Gemini CLI / Cursor / other):**
> This is an executable runbook. The fastest path is `./setup.sh` (it does everything below and
> verifies it). Use this doc to understand each piece, to install on a tool that isn't Claude
> Code, or to fix/extend by hand. Work top-to-bottom; each section ends with a **Verify** gate —
> don't move on until it passes. **Never enter the user's passwords, API keys, or logins** — when
> a step needs one, stop and ask them.

## ▶ What to run (agent quickstart)

**If you are an AI agent asked to set this up on this machine, do exactly this:**

```bash
# 0. Be in the repo (it contains setup.sh + this file). If you're not:
git clone https://github.com/FouL06/token-reducer && cd token-reducer

# 1. See what's installed vs missing (read-only, changes nothing):
./setup.sh check

# 2. Install everything missing + deploy all config (idempotent, backs up, never clobbers ~/.claude):
./setup.sh

# 3. Confirm it works (7 smoke tests — all should pass):
./setup.sh verify
```

`./setup.sh` (step 2) auto-installs and wires **all** of it: Homebrew, Node, pnpm, **Ollama + the
3 models + the tuned model**, **rtk** (+ the `rtk-extend` hook), the **context-mode** plugin,
**ccusage**, **claude-code-router**, the **11 subagents**, `~/.claude/CLAUDE.md` routing, the
`settings.json` hooks, and the start/end scripts. It's resumable and safe to re-run.

**Prereqs the script can't do for you (it will tell you):**
- **Claude Code** must already be installed + logged in (needed for the context-mode plugin + the
  agents). If `claude` is missing, install it first: <https://docs.anthropic.com/claude-code>.
- After it finishes, it prints **optional credential steps** — the **Anthropic API key** for
  `~/.claude-code-router/config.json` (only for free local routing via `ccr code`) and `claude`
  login. **Do not enter these for the user** — surface them and let the user do it.
- **Restart Claude Code** at the end so the new hooks/agents/CLAUDE.md load.

Other modes: `./setup.sh --dry-run` (print actions, change nothing) · `./uninstall.sh` (clean
revert). The sections below explain each piece and cover **manual / non-Claude-Code** (Codex,
Cursor, Gemini) installs.

## What you get + why it works

A stack that cuts an AI coding agent's **context tokens by ~86–94%** with **no loss of
decision-relevant information** (proven on real builds: tests + production build pass from the
distilled briefs alone). Three levers, biggest first:

1. **Subagent isolation** — research/scan/summarize/gather work runs in *separate* context
   windows; only a tight brief returns to the main window. On a real Next.js+Three.js build, the
   research phase was ~25K tokens of docs/reasoning → ~1.4K of briefs (−95%). This is the dominant
   win on anything research-heavy.
2. **Output compression (rtk)** — a Rust proxy that filters verbose command output (tests, lint,
   `git`, `docker`, `kubectl`, …). 80–99% on those commands.
3. **Local routing (free)** — cheap gather/verify agents run on a **local Ollama model ($0)**
   instead of the cloud; only synthesis/review hit the paid model.

Cost on a real session dropped ~40% (cloud Haiku gather) to ~62% (local gather), with the local
model's tokens counted as **free** (only what the cloud model used is counted/charged).

## Decisions (so you don't relearn them the hard way)

- **Ollama via the official app, NOT Homebrew.** The brew bottle ships the MLX lib but **not the
  `llama-server` runner** → every GGUF model 500s. Use `Ollama-darwin.zip` from ollama.com.
- **Models:** `qwen3-coder:30b` is the daily driver (fast MoE, best local tool-calling in our
  benchmarks, 6/6). `gpt-oss:20b` (reasoning fallback), `glm-4.7-flash` (tool-call accuracy). A
  tuned `qwen3-coder-tuned` pins Qwen's sampling + `num_ctx 32768`.
- **effort `high`, not `xhigh`** — xhigh maxes reasoning/output tokens; high is the better
  default for a token-reduction setup. Escalate per task.

---

# Universal core (works with ANY AI CLI)

These three are tool-agnostic. `setup.sh` installs all of them.

### 1. Ollama + local models
```bash
# Official app (NOT brew):
curl -fsSL -o /tmp/Ollama-darwin.zip https://ollama.com/download/Ollama-darwin.zip
ditto -x -k /tmp/Ollama-darwin.zip /Applications/ && xattr -dr com.apple.quarantine /Applications/Ollama.app
launchctl setenv OLLAMA_KEEP_ALIVE 1h && open -a Ollama
ollama pull qwen3-coder:30b && ollama pull gpt-oss:20b && ollama pull glm-4.7-flash
printf 'FROM qwen3-coder:30b\nPARAMETER temperature 0.7\nPARAMETER top_p 0.8\nPARAMETER top_k 20\nPARAMETER repeat_penalty 1.05\nPARAMETER num_ctx 32768\n' > /tmp/Modelfile && ollama create qwen3-coder-tuned -f /tmp/Modelfile
```
**Verify:** `curl -s localhost:11434/api/version` returns JSON; a `/api/chat` call with a `tools`
array returns a `tool_calls` array (not text). `ollama show qwen3-coder:30b` lists `tools`.

### 2. rtk (output compression) — multi-tool
`rtk`'s hook supports **`claude`, `cursor`, `gemini`, `copilot`** (`rtk hook --help`). Install once;
point whichever tool you use at it.
```bash
brew install rtk        # or: curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh
rtk init -g             # wires rtk's hook + RTK.md into your assistant config (optional —
                        # token-reducer installs its own rtk-extend hook regardless)
```
**Verify:** `rtk gain` works; `echo '{"tool_name":"Bash","tool_input":{"command":"git status"}}' | rtk hook claude` returns an `updatedInput` rewrite.

### 3. ccusage (spend tracking)
```bash
npm i -g ccusage   # `ccusage --json` → totals.totalCost; per-day in .daily[].totalCost
```
(`rtk cc-economics` is broken on current ccusage JSON; use `ccusage` directly — see the
`session-economics.mjs` script.)

---

# Claude Code adapter

The high-leverage layer. `setup.sh` deploys all of this into `~/.claude` (merging, never
clobbering) and `~/.claude-code-router`.

- **context-mode plugin** — sandboxes large tool output into SQLite/FTS5 and serves it back via
  search instead of dumping it into context:
  `claude plugin marketplace add mksglu/context-mode && claude plugin install context-mode@context-mode --scope user`.
  *Requires Claude Code (recent) + Node; it ships its **own native SQLite/FTS5 module** (not
  `node:sqlite`). Verify it loaded with its headless doctor:
  `node ~/.claude/plugins/cache/context-mode/context-mode/*/cli.bundle.mjs doctor` — `setup.sh verify` runs this.*
- **Agent fleet** (`~/.claude/agents/*.md`) — 11 subagents: GATHER (`scanner`, `summarizer`,
  `doc-retriever`, `extractor`, `tool-caller`, `triager` — Haiku/local), BUILD (`planner`,
  `writer` — Sonnet), VERIFY (`verifier`, `test-runner` — Haiku; `reviewer` — Sonnet).
- **`~/.claude/CLAUDE.md`** — `# modelRouting` (which agent for which job) + `# tokenLanes`
  (Bash→rtk for simple verbose commands; `ctx_execute` for compound/piped; whole test/build/lint
  → `test-runner` subagent).
- **`~/.claude/settings.json` hooks** — `PreToolUse` → `rtk-extend.mjs` (widens rtk to
  pnpm/docker/kubectl/…); `SessionStart` → cache-heal + `token-saver-up.sh` (brings Ollama+CCR up,
  warms the model); `SessionEnd` → `session-economics.mjs` (logs spend+savings). `effortLevel: high`.
- **claude-code-router (CCR)** — `~/.claude-code-router/config.json` maps the **local Ollama**
  provider + your cloud provider. Each gather/verify agent's prompt starts with
  `<CCR-SUBAGENT-MODEL>ollama,qwen3-coder-tuned</CCR-SUBAGENT-MODEL>`, so under `ccr code` those
  run free on local while `planner`/`reviewer`/main stay cloud. Plain `claude` ignores the tag.
  **Billing caveat:** `ccr code` bills cloud routes per API token (not your subscription) — use it
  when you want free local gather; use plain `claude` for normal subscription work.

**Verify:** `./setup.sh verify` — expects ollama tool-call ✓, rtk-extend rewrites `pnpm test` ✓,
CCR routes to local qwen ✓, 11 agents ✓, settings.json valid ✓, session-economics runs ✓.

---

# Codex / other CLI notes (honest)

The **universal core** above (Ollama, rtk, ccusage) works as-is. For the Claude-specific layer:

| Claude Code piece | Codex / other |
|---|---|
| `~/.claude/CLAUDE.md` | Codex reads `AGENTS.md` — put the routing/tokenLanes guidance there. |
| `rtk hook claude` (settings.json) | Use `rtk hook copilot` / `cursor` / `gemini` per `rtk hook --help`; wire it into that tool's hook/config mechanism. |
| Subagents (`~/.claude/agents`) | **No portable equivalent.** Codex has no first-class user-subagent model yet — emulate by instructing the agent (in `AGENTS.md`) to shell out to a local `ollama run` for gather/summarize, or skip. |
| context-mode plugin | **Claude Code only** (it's a CC plugin). No Codex equivalent; rely on the universal core. |
| CCR local routing | CCR proxies the Anthropic API shape; for non-Anthropic CLIs use that tool's own provider/base-URL config to point at Ollama (`localhost:11434/v1`). |

Be honest with the user about which pieces don't carry over rather than faking equivalents.

---

# Credentials the user must provide (never auto-enter)

- **Claude Code login** (`claude` must be installed + logged in for the plugin/agents).
- **Anthropic API key** in `~/.claude-code-router/config.json` (replace
  `REPLACE_WITH_YOUR_ANTHROPIC_API_KEY`, then `ccr restart`) — only for *cloud* routes under
  `ccr code`. The local stack works without it.
- **`gh auth`** — only to push this repo.

# Troubleshooting

| Symptom | Fix |
|---|---|
| Ollama model 500s "llama-server not found" | You installed via brew. Remove it; use the official app (see Universal core). |
| `rtk gain` empty / 0.5% coverage | Mostly a measurement artifact — the hook rewrites at execution, which `rtk discover` can't see. Real simple-command coverage ≈ 94% with `rtk-extend.mjs`. |
| Subagent doesn't run on local under `ccr code` | Confirm the `<CCR-SUBAGENT-MODEL>` tag is the FIRST line of the agent's prompt and CCR is running (`ccr status`, port 3456). |
| `ccr code` cloud routes error | Anthropic key still the placeholder — add it + `ccr restart`. |
| Hooks/agents not active | Restart Claude Code; settings/agents load at session start. |
| Bash commands stall (~15s) or fail / get `rtk`-prefixed | Old `rtk-extend` hook + a broken/missing rtk. Re-run `./setup.sh` to deploy the **fail-safe** hook: if rtk can't run, it now passes the command through instantly (no stall, no rewrite) instead of breaking it. |
| context-mode `ctx_*` tools missing/erroring | Its native SQLite/FTS5 module didn't load. Run `node ~/.claude/plugins/cache/context-mode/context-mode/*/cli.bundle.mjs doctor`; on a FAIL, reinstall the plugin (`claude plugin install context-mode@context-mode --scope user`) or update Node. `setup.sh verify` runs this check. |
| context-mode hangs / blocks sessions | Unblock everything else immediately by disabling just it: `claude plugin disable context-mode@context-mode` then restart Claude Code. rtk, Ollama, the agents, and routing all work without it. Re-enable once its doctor passes. |

# Rollback

```bash
# restore the timestamped backups setup.sh wrote:
ls ~/.claude/settings.json.bak.*  ~/.claude/CLAUDE.md.bak.*
# remove deployed pieces:
rm -f ~/.claude/agents/{scanner,planner,reviewer,summarizer,test-runner,doc-retriever,extractor,tool-caller,writer,verifier,triager}.md
rm -f ~/.claude/hooks/rtk-extend.mjs ~/.claude/scripts/{token-saver-up.sh,session-economics.mjs}
# then hand-remove the hooks/effortLevel from settings.json and the # modelRouting / # tokenLanes blocks from CLAUDE.md.
claude plugin uninstall context-mode@context-mode   # optional
```
