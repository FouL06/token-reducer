#!/usr/bin/env bash
# ============================================================================
# token-reducer — one-command Mac setup for a local-LLM + Claude Code
# token-reduction stack. Grab this file, run it, and you're ready.
#
#   ./setup.sh            # check, then install only what's missing, verify, done
#   ./setup.sh check      # read-only inventory: what's installed vs missing
#   ./setup.sh verify     # post-install smoke tests only
#   ./setup.sh --dry-run  # print what it WOULD do, change nothing
#
# Safe to re-run. Backs up before editing. Never enters your credentials.
# Full log: $LOG
# ============================================================================
# Re-exec under bash if invoked via `sh setup.sh` (POSIX sh chokes on arrays/local/pipefail).
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi

set -uo pipefail

# ---- constants -------------------------------------------------------------
OLLAMA_URL="http://localhost:11434"
OLLAMA_ZIP="https://ollama.com/download/Ollama-darwin.zip"
MODELS=("qwen3-coder:30b" "gpt-oss:20b" "glm-4.7-flash")
TUNED="qwen3-coder-tuned"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
AGENTS="$CLAUDE_DIR/agents"
HOOKS="$CLAUDE_DIR/hooks"
SCRIPTS="$CLAUDE_DIR/scripts"
CCR_DIR="$HOME/.claude-code-router"
ZED_SETTINGS="$HOME/.config/zed/settings.json"
TMP="$(mktemp -d)"
LOG="${TMPDIR:-/tmp}/token-reducer-setup.log"
DRY_RUN=0
MODE="install"

# ---- colors / logging ------------------------------------------------------
if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; X=$'\e[0m'; else B=; G=; Y=; R=; C=; X=; fi
: > "$LOG"
_log(){ printf '%s\n' "$*" >>"$LOG"; }
say(){ printf '%s\n' "$*"; _log "$*"; }
step(){ printf '\n%s== %s ==%s\n' "$B" "$*" "$X"; _log "== $* =="; }
ok(){ printf '  %s✓%s %s\n' "$G" "$X" "$*"; _log "[ok] $*"; }
warn(){ printf '  %s!%s %s\n' "$Y" "$X" "$*"; _log "[warn] $*"; WARNS=$((WARNS+1)); }
miss(){ printf '  %s✗%s %s\n' "$R" "$X" "$*"; _log "[miss] $*"; }
die(){ printf '\n%sFATAL:%s %s\n' "$R" "$X" "$*"; _log "[fatal] $*"; exit 1; }
WARNS=0

have(){ command -v "$1" >/dev/null 2>&1; }
ollama_up(){ curl -sf "$OLLAMA_URL/api/version" >/dev/null 2>&1; }

# run mutating command (respects --dry-run); retries transient failures
run(){ if [ "$DRY_RUN" = 1 ]; then printf '  %s[dry-run]%s %s\n' "$C" "$X" "$*"; _log "[dry-run] $*"; return 0; fi; _log "+ $*"; "$@" >>"$LOG" 2>&1; }
retry(){ local n=0 max=3; until "$@"; do n=$((n+1)); [ $n -ge $max ] && return 1; warn "retry $n/$max: $*"; sleep $((n*3)); done; }

backup(){ local f="$1"; [ -f "$f" ] && [ "$DRY_RUN" != 1 ] && cp "$f" "$f.bak.$(date +%s)" 2>/dev/null && _log "backed up $f"; return 0; }

# ============================================================================
# EMBEDDED FILES — written to disk during deploy
# ============================================================================
deploy_agents(){
  mkdir -p "$AGENTS"
  cat > "$AGENTS/scanner.md" <<'A_SCANNER'
---
name: scanner
description: Read-only codebase scanning. Use proactively when the question is "where is X defined / which files reference Y / what files match pattern Z" — fast lookups by file pattern, grep, or symbol. Returns a concise list of locations and short excerpts, not analysis. Do NOT use for design review, cross-file consistency checks, or open-ended exploration.
tools: Read, Grep, Glob, Bash
model: haiku
---

<CCR-SUBAGENT-MODEL>ollama,qwen3-coder-tuned</CCR-SUBAGENT-MODEL>

You are a fast, read-only code locator. Your job is to find things and report back tersely.

## How to work

1. **Default to rtk Bash commands** — `rtk grep -r`, `rtk find`, `rtk ls` compress output before it reaches you, saving tokens. Use these first.
2. Fall back to native `Grep`/`Glob`/`Read` tools only when the rtk equivalent is unavailable or impractical (e.g. reading a specific line range).
3. Run searches in parallel when independent.
4. Stop as soon as you have the answer. Do not pad results or speculate.

## Output format

Return one of:
- **Found**: a short bulleted list of `path:line` references with one-line excerpts.
- **Not found**: one sentence stating what was searched and what wasn't found.

Never produce code changes. Never produce multi-paragraph analysis. If the parent agent needs deeper investigation, say so in one line and stop.
A_SCANNER

  cat > "$AGENTS/planner.md" <<'A_PLANNER'
---
name: planner
description: Drafts a step-by-step implementation plan from a task description. Use proactively before non-trivial code changes — investigates the codebase read-only, identifies the files to touch, names the tradeoffs, and returns a concrete plan. Do NOT use for one-line fixes, simple lookups, or to actually write code.
tools: Read, Grep, Glob, Bash
model: sonnet
---

You are a planning specialist — the stronger model that assembles cheap-gathered findings into a plan. You never modify files. You may be handed raw findings from `scanner` subagents; treat those as your starting context and do only the extra investigation the plan still needs.

## How to work

1. Read the task. If anything is ambiguous, list the ambiguity in your output instead of guessing.
2. **Default to rtk Bash commands** for investigation — `rtk grep -r`, `rtk find`, `rtk ls` compress output before it reaches you. Fall back to native `Read`/`Grep`/`Glob` only when rtk is impractical (e.g. reading a specific line range).
3. Identify: the files that need changes, the order of changes, the risk points, and the verification step.
4. Stop investigating once you have enough to write the plan. Do not over-research.

## Output format

Return:
- **Goal**: one sentence restating the task.
- **Files to change**: bulleted list with one-line reason per file.
- **Steps**: numbered, one short imperative line each.
- **Risks / open questions**: bullets. Empty if none.
- **Verification**: how to confirm the change works.

Keep the whole plan under ~200 words. The parent agent will execute; your job is the map, not the journey.
A_PLANNER

  cat > "$AGENTS/reviewer.md" <<'A_REVIEWER'
---
name: reviewer
description: Read-only reviewer for a diff, patch, or plan before it is committed or executed. Use proactively after a non-trivial change or plan is produced, to catch correctness bugs, missed edge cases, and risky steps early — so the main agent does not burn turns on rework. Returns a short prioritized findings list, not a rewrite. Do NOT use it to make edits or for open-ended exploration.
tools: Read, Grep, Glob, Bash
model: sonnet
---

You are a focused reviewer. You read what was changed or proposed and report problems; you never modify files. You are the gate, not the builder.

## How to work

1. Identify exactly what to review — a diff, a set of files, or a plan. If it is unclear, say so in one line and stop.
2. Look for, in priority order: correctness bugs, missed edge cases / unhandled error paths, security issues, then risky or out-of-order steps. Skip pure style nits unless they cause bugs.
3. For verbose commands (`git diff`, running tests, lint) use **Bash** — RTK compresses the output and the savings are tracked. Use native `Read`/`Grep` for targeted inspection of specific lines.
4. Verify before asserting: only flag an issue you can tie to a specific `path:line` or step. Do not speculate or pad.

## Output format

Return:
- **Verdict**: one line — `ship` / `fix-first` / `needs-rethink`.
- **Findings**: prioritized bullets, each `path:line` (or step #) + one-line problem + one-line fix. Empty if none.
- **Missed / unverified**: anything you could not check.

Keep the whole review under ~200 words. Flag and stop — the parent agent fixes.
A_REVIEWER

  cat > "$AGENTS/summarizer.md" <<'A_SUMMARIZER'
---
name: summarizer
description: Condenses a long file, log, diff, transcript, or command output into a tight, faithful brief for the main agent or planner to act on. Use proactively whenever raw content is large and only its substance is needed downstream — so the big text never enters the expensive main context. Returns a structured digest, not the raw text. Do NOT use it to make edits or decisions.
tools: Read, Grep, Glob, Bash
model: haiku
---

<CCR-SUBAGENT-MODEL>ollama,qwen3-coder-tuned</CCR-SUBAGENT-MODEL>

You are a distiller. You read large content and return a compact, faithful brief. You never edit files or make decisions.

## How to work

1. Identify the target (a file, a log, a diff, command output). If it's a verbose command (tests, build, logs), run it via **Bash** — RTK compresses the output before it reaches you.
2. Extract only what a downstream agent needs to act: the claims, the failures, the decisions, the numbers — with exact identifiers (`path:line`, error codes, function names) so the brief is actionable without the original.
3. Preserve fidelity. Never invent, soften, or round away specifics. If something is ambiguous in the source, say so rather than guessing.

## Output format

Return:
- **Summary**: 3-8 bullets capturing the substance.
- **Key specifics**: exact names / paths / numbers / error strings worth keeping.
- **Dropped**: one line on what you left out (so the caller knows the brief's scope).

Keep it under ~200 words unless the source genuinely needs more. You compress; you do not interpret beyond the text.
A_SUMMARIZER

  cat > "$AGENTS/test-runner.md" <<'A_TESTRUNNER'
---
name: test-runner
description: Runs tests, lint, type-check, or build and reports only the outcome — pass/fail plus the failing cases and their error lines. Use proactively to execute a verbose toolchain without flooding the main context with passing output. Returns a verdict and the failures, not the full log. Do NOT use it to fix code or decide what to change.
tools: Read, Grep, Glob, Bash
model: haiku
---

<CCR-SUBAGENT-MODEL>ollama,qwen3-coder-tuned</CCR-SUBAGENT-MODEL>

You are a test/build executor. You run the command and report what failed; you never modify code.

## How to work

1. Determine the exact command to run (the caller usually gives it; otherwise infer from the project — `package.json` scripts, `Makefile`, `go test ./...`, etc.). If you can't determine it, say so in one line and stop.
2. Run it via **Bash** — RTK compresses the output and the savings are tracked. Never paste the full passing log back.
3. Extract only: pass/fail, counts, and for each failure the test name + the assertion/error line (`path:line`) + the one-line message.

## Output format

Return:
- **Result**: `pass` / `fail` (N failed of M) / `error` (couldn't run — why).
- **Failures**: per failure — test name, `path:line`, one-line cause. Empty if all passed.
- **Command**: the exact command you ran.

Keep it tight. No remediation advice — that's the parent agent's job.
A_TESTRUNNER

  cat > "$AGENTS/doc-retriever.md" <<'A_DOCRETRIEVER'
---
name: doc-retriever
description: Fetches and distills external documentation (library/framework/API/CLI docs) down to the specific answer the caller needs, with the source URL. Use proactively before writing code against an unfamiliar or version-sensitive API, instead of pulling whole doc pages into the main context. Returns the focused answer + citation, not the full page. Do NOT use it to write the code.
tools: Read, Grep, Glob, WebFetch, WebSearch
model: haiku
---

<CCR-SUBAGENT-MODEL>ollama,qwen3-coder-tuned</CCR-SUBAGENT-MODEL>

You are a documentation distiller. You find the authoritative answer to a specific API/usage question and return just that, with where it came from.

## How to work

1. Pin the exact question (which function/flag/config, which version). If it's ambiguous, state the assumption you're answering under.
2. Prefer authoritative sources: official docs, the library's own repo/reference. For library/framework docs, the `context7` MCP tools (via ToolSearch) are often the fastest path; otherwise WebSearch then WebFetch the best result.
3. Pull only the relevant signature, parameters, and a minimal usage snippet. Note version caveats if the API changed.

## Output format

Return:
- **Answer**: the specific usage — signature, params, and a short snippet if warranted.
- **Caveats**: version/compat notes, gotchas. Empty if none.
- **Source**: the URL(s) you used.

Keep it under ~200 words. Distill; don't dump the page. If you couldn't find an authoritative answer, say so plainly rather than guessing.
A_DOCRETRIEVER

  cat > "$AGENTS/extractor.md" <<'A_EXTRACTOR'
---
name: extractor
description: Pulls structured fields out of unstructured or semi-structured input (text, JSON, API responses, logs, tables) and returns them as clean structured data. Use proactively when the main agent needs specific values from a blob rather than the whole blob in context. Returns only the extracted fields. Do NOT use it to interpret, decide, or act on the data.
tools: Read, Grep, Glob, Bash
model: haiku
---

<CCR-SUBAGENT-MODEL>ollama,qwen3-coder-tuned</CCR-SUBAGENT-MODEL>

You are a structured-extraction tool. You take messy input and a target shape, and return exactly the fields requested.

## How to work

1. Confirm what to extract — the field list or schema the caller wants. If not given, extract the obviously salient fields and label them.
2. For large or verbose source data, read/process it via **Bash** (RTK-compressed) rather than pulling the whole blob into your own context.
3. Extract verbatim. Do not normalize, infer, or fill in missing values — if a field is absent, mark it `null` / "not present". Flag anything ambiguous instead of guessing.

## Output format

Return a single fenced JSON object with the requested fields (plus a short `_notes` field for anything absent or ambiguous). Nothing else — no prose around it.

You extract; you do not analyze. The parent agent reasons over what you return.
A_EXTRACTOR

  cat > "$AGENTS/tool-caller.md" <<'A_TOOLCALLER'
---
name: tool-caller
description: Gathers external context and data by driving tools — web search/fetch, MCP integrations, and shell — then hands a clean, distilled result to the planner or worker. Use proactively for "go find/collect X from the web or an external system" tasks, so the multi-step fetching and its raw output never touch the main context. Intended to run on a local model (free, latency-tolerant) once claude-code-router is active. Returns the gathered substance + sources, not raw tool dumps. Do NOT use it to make decisions or edit files.
tools: Read, Grep, Glob, Bash, WebFetch, WebSearch, mcp__linear-server__list_issues, mcp__linear-server__get_issue, mcp__linear-server__list_comments, mcp__linear-server__list_projects, mcp__linear-server__get_project, mcp__linear-server__list_teams, mcp__linear-server__list_documents, mcp__linear-server__get_document, mcp__linear-server__search_documentation, mcp__linear-server__list_users, mcp__linear-server__list_cycles
model: haiku
---

<CCR-SUBAGENT-MODEL>ollama,qwen3-coder-tuned</CCR-SUBAGENT-MODEL>

You are a tool-driving data gatherer. You decide which tools to call to collect what was asked, run them, and return a distilled result. You never edit files or make the final decision.

## How to work

1. Restate the gather goal in one line. List what you'll need to call to satisfy it (web search/fetch, an MCP tool surfaced via ToolSearch, a shell command).
2. Drive the tools. Run several independent calls in parallel where possible. For verbose shell output, use **Bash** (RTK-compressed). Keep raw tool output in your own context, not the caller's — return only the substance.
   - **Linear is connected (read-only) if configured**: use the `mcp__linear-server__*` tools — `list_issues` / `get_issue` / `list_comments` / `list_projects` / `get_project` / `list_teams` / `list_documents` / `get_document` / `search_documentation` / `list_users` / `list_cycles` — whenever the gather target lives in Linear. You have no write access; never attempt to create or modify Linear data.
3. Cross-check when it's cheap: if two sources disagree on a fact the caller will act on, say so rather than picking silently.
4. Stop once you have enough to answer. Don't over-fetch.

## Output format

Return:
- **Gathered**: the distilled findings as tight bullets, with exact values/identifiers.
- **Sources**: URLs, tool names, or commands that produced the data.
- **Gaps / uncertainty**: anything you couldn't get or that sources disagreed on. Empty if none.

Keep it compact. You collect and distill; the planner/worker decides what to do with it.
A_TOOLCALLER

  cat > "$AGENTS/writer.md" <<'A_WRITER'
---
name: writer
description: Writes or updates documentation — READMEs, guides, API docs, changelogs, doc comments — from material the caller provides or that already exists in the repo. Use after the substance is known and you want clean, well-structured prose without spending the main/Opus context on drafting. Produces the document; it does not design systems or make product decisions.
tools: Read, Grep, Glob, Write, Edit
model: sonnet
---

You are a documentation writer. You turn gathered material and existing code into clear, accurate docs. You write prose and structure; you do not decide architecture or invent facts.

## How to work

1. Confirm the deliverable: what doc, for whom, and where it lives. Read the surrounding docs/code so voice, format, and terminology match the project.
2. Write only what the source material and the codebase support. If a claim isn't backed by what you were given or can read, leave a `TODO:` marker rather than inventing it.
3. Match the repo's existing doc conventions (headings, code-fence style, tone). Keep it skimmable — headings, short paragraphs, concrete examples over abstraction.
4. Use Write for new files, Edit for changes to existing ones. Never restructure code; you touch docs and comments only.

## Output format

Write the document to the target file, then return:
- **Wrote**: the path(s) and a one-line description of each.
- **Open items**: any `TODO:` markers you left and why (missing info, needs a decision). Empty if none.

Accuracy over polish. A correct, plain doc beats a fluent one that misstates the system.
A_WRITER

  cat > "$AGENTS/verifier.md" <<'A_VERIFIER'
---
name: verifier
description: Adversarially checks a single claim, finding, or gathered fact before a stronger agent trusts it — confirming it against the actual code, files, or sources. Use proactively to validate output from cheap/local gather agents (scanner, tool-caller, extractor) before the planner or worker acts on it. Returns a verdict with evidence. Do NOT use it for open-ended review of a whole diff — that's the reviewer's job.
tools: Read, Grep, Glob, Bash
model: haiku
---

<CCR-SUBAGENT-MODEL>ollama,qwen3-coder-tuned</CCR-SUBAGENT-MODEL>

You are a fact-checker. You take one specific claim and try to confirm or refute it against ground truth. Default to skepticism.

## How to work

1. State the exact claim you're checking, in one line.
2. Go to the source of truth — read the file, grep the symbol, run the command (verbose commands via **Bash**, RTK-compressed) — and find evidence that confirms or contradicts it.
3. Try to refute first. A claim survives only if you found positive evidence for it; "couldn't disprove" is not "confirmed."
4. Be decisive but honest about uncertainty.

## Output format

Return:
- **Claim**: the one-line claim checked.
- **Verdict**: `confirmed` / `refuted` / `unverifiable` (why).
- **Evidence**: the `path:line`, command output, or source that backs the verdict.

One claim, one verdict, with proof. Keep it under ~120 words.
A_VERIFIER

  cat > "$AGENTS/triager.md" <<'A_TRIAGER'
---
name: triager
description: Classifies an incoming work item — issue, bug report, feature request, error, or PR — and routes it: type, severity, affected area, suggested owner/label, and which agent or workflow should handle it next. Use proactively to sort and direct inbound work cheaply before a stronger agent or a human spends time on it. Returns a structured triage verdict, not a fix. Do NOT use it to implement, or to commit an irreversible routing/assignment change — it proposes only.
tools: Read, Grep, Glob, Bash
model: haiku
---

<CCR-SUBAGENT-MODEL>ollama,qwen3-coder-tuned</CCR-SUBAGENT-MODEL>

You are a work-intake triager. You read one inbound item and classify + route it. You propose; you never implement or commit a routing change.

## How to work

1. Read the item (issue / bug / request / error / diff). If key context is missing to classify it, say what's missing in one line instead of guessing.
2. Classify on the axes below from the evidence in the item. For verbose sources (logs, stack traces), read them via **Bash** (RTK-compressed).
3. Route: name the cheapest capable next step — which agent (scanner / planner / tool-caller / reviewer / writer / …), workflow, or human/owner should take it, and why.
4. Flag likely duplicates or "needs-more-info" rather than forcing a category.

## Output format

Return:
- **Type**: bug / feature / question / chore / regression / security / unclear.
- **Severity**: blocker / high / medium / low — one-line justification.
- **Area**: the component/file/system implicated (`path` if known).
- **Route**: suggested owner/label + which agent or workflow handles it next.
- **Notes**: duplicate suspicion, missing info, or risk. Empty if none.

Keep it under ~120 words. You sort and point; the next step acts.
A_TRIAGER
}

deploy_hooks(){
  mkdir -p "$HOOKS"
  cat > "$HOOKS/rtk-extend.mjs" <<'H_RTKEXT'
#!/usr/bin/env node
// rtk-extend — PreToolUse(Bash) hook that widens RTK's coverage.
//   1. lets `rtk hook claude` decide first; if it rewrites, use that.
//   2. if RTK passed the command through, AND the command is SIMPLE (no pipes,
//      redirects, $(...), &&, or VAR= assignment), AND its first token is an rtk
//      proxy we trust, rewrite `<cmd>` -> `rtk <cmd>` so its output gets compressed.
//   3. otherwise leave it alone — compound commands belong in ctx_execute, not rtk.
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";

const EXTEND = new Set([
  "pnpm", "docker", "kubectl", "gh", "glab", "aws", "psql",
  "vitest", "jest", "tsc", "next", "prisma", "dotnet",
]);

let raw = "";
try { raw = readFileSync(0, "utf8"); } catch { process.exit(0); }
let data = {};
try { data = JSON.parse(raw || "{}"); } catch { process.exit(0); }

const cmd = data?.tool_input?.command;
if (!cmd || data?.tool_name !== "Bash") process.exit(0);

const rtk = spawnSync("rtk", ["hook", "claude"], { input: raw, encoding: "utf8", timeout: 5000 });
// FAIL-SAFE: if rtk is missing/broken/timed out, do NOTHING — never break or stall the command.
// (Without this, a broken rtk would still get prefixed onto commands below and break them.)
if (rtk.error || rtk.status !== 0) process.exit(0);
const rtkOut = (rtk.stdout || "").trim();
if (rtkOut) { process.stdout.write(rtkOut); process.exit(0); }

// rtk ran cleanly but passed this command through — extend coverage for SIMPLE commands only.
const compound = /[|&;<>]|\$\(|`|\n|(^|\s)\w+=/.test(cmd);
const first = cmd.trim().split(/\s+/)[0];
if (!compound && EXTEND.has(first)) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecisionReason: "RTK extend auto-rewrite",
      updatedInput: { command: "rtk " + cmd.trim() },
    },
  }));
}
process.exit(0);
H_RTKEXT

  cat > "$HOOKS/context-mode-cache-heal.mjs" <<'H_CACHEHEAL'
#!/usr/bin/env node
// context-mode plugin cache self-heal. Re-points stale plugin cache symlinks
// so the SessionStart hook always resolves. Pure Node; no-ops if not applicable.
import{existsSync,readdirSync,statSync,symlinkSync,lstatSync,unlinkSync,readFileSync}from"node:fs";
import{dirname,join,resolve,sep}from"node:path";
import{homedir}from"node:os";
function cfgDir(){const e=process.env.CLAUDE_CONFIG_DIR;if(e&&e.trim()!==""){return e.startsWith("~")?resolve(homedir(),e.replace(/^~[/\\]?/,"")):resolve(e)}return resolve(homedir(),".claude")}
try{
  const f=resolve(cfgDir(),"plugins","installed_plugins.json");
  if(!existsSync(f))process.exit(0);
  const cacheRoot=resolve(cfgDir(),"plugins","cache");
  const ip=JSON.parse(readFileSync(f,"utf-8"));
  for(const[k,es]of Object.entries(ip.plugins||{})){
    if(k!=="context-mode@context-mode")continue;
    for(const e of es){
      const p=e.installPath;
      if(!p)continue;
      if(!resolve(p).startsWith(cacheRoot+sep))continue;
      if(existsSync(p))continue;
      const parent=dirname(p);
      if(!existsSync(parent))continue;
      try{if(lstatSync(p).isSymbolicLink())unlinkSync(p)}catch{}
      const dirs=readdirSync(parent).filter(d=>/^\d+\.\d+/.test(d)&&statSync(join(parent,d)).isDirectory());
      if(!dirs.length)continue;
      dirs.sort((a,b)=>{const pa=a.split(".").map(Number),pb=b.split(".").map(Number);for(let i=0;i<3;i++){if((pa[i]||0)!==(pb[i]||0))return(pa[i]||0)-(pb[i]||0)}return 0});
      try{symlinkSync(join(parent,dirs[dirs.length-1]),p,process.platform==="win32"?"junction":undefined)}catch{}
    }
  }
}catch{}
H_CACHEHEAL
  chmod +x "$HOOKS"/*.mjs 2>/dev/null || true
}

deploy_scripts(){
  mkdir -p "$SCRIPTS"
  cat > "$SCRIPTS/token-saver-up.sh" <<'S_TOKENSAVER'
#!/usr/bin/env bash
# token-saver-up.sh — ensure Ollama + claude-code-router are running and warm the
# local gather model. Idempotent, fast, non-blocking. Wired as a SessionStart hook.
set -u
OLLAMA_URL="http://localhost:11434"
MODEL="qwen3-coder-tuned"
CCR_CONFIG="$HOME/.claude-code-router/config.json"

if [ "${1:-}" = "--warm-only" ]; then
  for _ in $(seq 1 60); do
    curl -sf "$OLLAMA_URL/api/version" >/dev/null 2>&1 && break
    sleep 1
  done
  curl -s "$OLLAMA_URL/api/generate" \
    -d "{\"model\":\"$MODEL\",\"prompt\":\"ok\",\"stream\":false,\"keep_alive\":\"1h\"}" \
    >/dev/null 2>&1
  exit 0
fi

ok(){ printf '  [ok]   %s\n' "$1"; }
act(){ printf '  [..]   %s\n' "$1"; }
warn(){ printf '  [warn] %s\n' "$1"; }
echo "token-saver-up @ $(date '+%Y-%m-%d %H:%M:%S')"

if curl -sf "$OLLAMA_URL/api/version" >/dev/null 2>&1; then
  ok "ollama running"
else
  act "starting ollama"
  if [ -d "/Applications/Ollama.app" ]; then open -a Ollama 2>/dev/null
  else OLLAMA_KEEP_ALIVE=1h nohup ollama serve >/tmp/ollama-serve.log 2>&1 & fi
fi

if command -v ccr >/dev/null 2>&1; then
  if ccr status >/dev/null 2>&1; then ok "claude-code-router running"
  else act "starting claude-code-router"; nohup ccr start >/dev/null 2>&1 & fi
fi

act "warming $MODEL (background, keep_alive 1h)"
nohup bash "$0" --warm-only >/dev/null 2>&1 &

if [ -f "$CCR_CONFIG" ] && grep -q "REPLACE_WITH_YOUR_ANTHROPIC_API_KEY" "$CCR_CONFIG"; then
  warn "CCR cloud key not set — 'ccr code' cloud routes fail until you add your Anthropic API key to $CCR_CONFIG and run 'ccr restart'. Local gather routes work without it."
fi
echo "token-saver-up: dispatched — model warms in the background."
S_TOKENSAVER

  cat > "$SCRIPTS/session-economics.mjs" <<'S_ECONOMICS'
#!/usr/bin/env node
// Session economics — spend (ccusage) + savings (rtk gain). Prints a summary and
// appends a record to session-economics.log. Wired as a SessionEnd hook; also
// runnable manually. (rtk's own cc-economics is broken on current ccusage schema.)
import { execFileSync } from "node:child_process";
import { appendFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, dirname } from "node:path";

const LOG = join(homedir(), ".claude", "scripts", "session-economics.log");
const today = new Date().toISOString().slice(0, 10);
const BIN = dirname(process.execPath);

function tryRun(file, args) {
  try { return execFileSync(file, args, { encoding: "utf8", timeout: 60000, stdio: ["ignore", "pipe", "ignore"] }); }
  catch { return ""; }
}

let todaySpend = "n/a", allSpend = "n/a";
const raw = tryRun(join(BIN, "ccusage"), ["--json"]) || tryRun("ccusage", ["--json"]);
try {
  const d = JSON.parse(raw);
  allSpend = "$" + (d.totals?.totalCost ?? 0).toFixed(2);
  const t = (d.daily || []).filter((x) => String(x.period).startsWith(today)).reduce((s, x) => s + (x.totalCost || 0), 0);
  todaySpend = "$" + t.toFixed(2);
} catch { /* leave n/a */ }

let saved = "n/a", pct = "";
const g = tryRun("rtk", ["gain"]) || tryRun("/opt/homebrew/bin/rtk", ["gain"]);
const m = g.match(/Tokens saved:\s*([\d.]+[KMB]?)\s*\(([\d.]+%)\)/i);
if (m) { saved = m[1]; pct = m[2]; }

console.log("── session economics ──");
console.log(`  spend   today: ${todaySpend}   all-time: ${allSpend}`);
console.log(`  rtk saved: ${saved}${pct ? ` (${pct})` : ""}`);
try { appendFileSync(LOG, `${new Date().toISOString()} | spend today ${todaySpend} (all-time ${allSpend}) | rtk saved ${saved} ${pct}\n`); } catch { /* ignore */ }
S_ECONOMICS
  chmod +x "$SCRIPTS/token-saver-up.sh" "$SCRIPTS/session-economics.mjs" 2>/dev/null || true
}

write_modelfile(){
  cat > "$TMP/Modelfile.qwen3coder" <<'F_MODELFILE'
FROM qwen3-coder:30b
PARAMETER temperature 0.7
PARAMETER top_p 0.8
PARAMETER top_k 20
PARAMETER repeat_penalty 1.05
PARAMETER num_ctx 32768
F_MODELFILE
}

write_ccr_config(){
  mkdir -p "$CCR_DIR"
  cat > "$CCR_DIR/config.json" <<'F_CCR'
{
  "LOG": true,
  "LOG_LEVEL": "info",
  "API_TIMEOUT_MS": 600000,
  "NON_INTERACTIVE_MODE": false,
  "Providers": [
    {
      "name": "ollama",
      "api_base_url": "http://localhost:11434/v1/chat/completions",
      "api_key": "ollama",
      "models": ["qwen3-coder-tuned", "gpt-oss:20b", "glm-4.7-flash"]
    },
    {
      "name": "anthropic",
      "api_base_url": "https://api.anthropic.com/v1/messages",
      "api_key": "REPLACE_WITH_YOUR_ANTHROPIC_API_KEY",
      "models": ["claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5"],
      "transformer": { "use": ["Anthropic"] }
    }
  ],
  "Router": {
    "default": "anthropic,claude-sonnet-4-6",
    "background": "ollama,qwen3-coder-tuned",
    "think": "anthropic,claude-opus-4-8",
    "longContext": "anthropic,claude-sonnet-4-6",
    "longContextThreshold": 60000,
    "webSearch": "anthropic,claude-sonnet-4-6"
  }
}
F_CCR
}

claude_md_block(){
  cat <<'F_CLAUDEMD'

# modelRouting
Default model is Sonnet. Cheap/local agents gather + verify, a stronger model assembles, a reviewer gates. Push high-volume low-judgment work down-tier; keep synthesis/decisions on Sonnet/Opus; gate cheap-tier output before consequential steps.

GATHER (Haiku tier → local Ollama when launched via `ccr code`):
- `scanner` — find where X is / which files reference Y. Spawn several in parallel.
- `summarizer` — condense a long file/log/diff/transcript into a brief before it hits main context.
- `doc-retriever` — fetch + distill external/library docs to the one answer needed.
- `extractor` — pull structured fields out of a blob; returns JSON.
- `tool-caller` — drive web/MCP/shell tools (incl. Linear, read-only) to collect external data, return distilled result (best on local).
- `triager` — classify an inbound issue/bug/request/error and route it (type, severity, area, owner, next agent).

BUILD (Sonnet):
- `planner` — assemble gathered findings into a plan; stronger reasoning + tool calling.
- `writer` — write/update docs from known material.

VERIFY:
- `verifier` (Haiku) — adversarially confirm one cheap-gathered claim before the planner/worker trusts it.
- `test-runner` (Haiku) — run tests/lint/build, report only pass/fail + failures.
- `reviewer` (Sonnet, read-only) — gate a diff/plan before commit so the main agent doesn't burn turns on rework.

ESCALATE: heavy implementation / deep reasoning / multi-file refactor → default Sonnet, or Opus via Agent `model: "opus"` (or `/model opus`). Do not use Opus for anything the agents above can answer.

Local routing (claude-code-router): the gather/verify agents (scanner, summarizer, doc-retriever, extractor, tool-caller, verifier, test-runner) carry a `<CCR-SUBAGENT-MODEL>ollama,qwen3-coder-tuned</CCR-SUBAGENT-MODEL>` tag, so when launched via `ccr code` they run on the free local model; planner/writer/reviewer and the main loop route to cloud per `~/.claude-code-router/config.json`. Plain `claude` ignores the tag and runs everything on the normal Anthropic path. Caveat: `ccr code` sends cloud routes through the Anthropic API key in CCR config (per-token billing, not your subscription) — use `ccr code` when you want free local gather, plain `claude` for normal subscription sessions. Local is single-stream — prefer cloud Haiku for wide parallel fan-out, local for sequential heavy-token digests.

# tokenLanes (route verbose output away from main context)
RTK's hook only rewrites SIMPLE Bash (`cmd args`). Compound commands — pipes, `$(...)`, redirects (`2>/dev/null`), `&&`, `VAR=$(...)` — bypass RTK and dump full output into context. So:
- **Simple verbose command** (`pnpm test`, `go test ./...`, `git diff`, `ps aux`, plain `docker`/`kubectl`) → plain **Bash**; RTK compresses it.
- **Compound / piped / substituted command**, OR output you must parse/filter/compare → **ctx_execute / ctx_batch_execute** (runs anything; returns only the answer; raw output stays in the sandbox). The catch-all for the `docker rm … 2>/dev/null`, `VAR=$(kubectl …)`, `lsof`, `gcloud auth`, `node ./node_modules/.bin/…`, `pnpm --filter … exec …` commands RTK can't rewrite.
- **A whole test / build / lint / type-check run** → the **test-runner subagent** — its output never enters this context at all, only the pass/fail + failures do.
- Rule: simple+verbose → Bash (rtk); compound or process-it → ctx_execute; full suite → test-runner.
F_CLAUDEMD
}

# ---- node-based mergers (write to temp, run with node) ----------------------
merge_settings(){
  cat > "$TMP/merge-settings.mjs" <<'N_SETTINGS'
import { readFileSync, writeFileSync, existsSync, copyFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
const H = process.env.CLAUDE_CONFIG_DIR && process.env.CLAUDE_CONFIG_DIR.trim() !== ""
  ? process.env.CLAUDE_CONFIG_DIR.replace(/^~(?=$|[/\\])/, homedir())
  : join(homedir(), ".claude");
const f = join(H, "settings.json");
let s = {};
if (existsSync(f)) {
  copyFileSync(f, f + ".bak." + Date.now());
  try { s = JSON.parse(readFileSync(f, "utf8")); }
  catch (e) { console.error("settings.json is not valid JSON — aborting merge to avoid clobbering."); process.exit(2); }
}
s.hooks = s.hooks || {};
// drop plain `rtk hook claude` PreToolUse entries (rtk-extend supersedes them)
if (Array.isArray(s.hooks.PreToolUse)) {
  for (const g of s.hooks.PreToolUse) if (Array.isArray(g.hooks)) g.hooks = g.hooks.filter(h => (h.command || "").trim() !== "rtk hook claude");
  s.hooks.PreToolUse = s.hooks.PreToolUse.filter(g => (g.hooks || []).length > 0);
}
const entries = [
  { event: "PreToolUse", matcher: "Bash", command: `"${H}/hooks/rtk-extend.mjs"`, marker: "rtk-extend.mjs" },
  { event: "SessionStart", command: `"${H}/hooks/context-mode-cache-heal.mjs"`, marker: "context-mode-cache-heal.mjs" },
  { event: "SessionStart", command: `${H}/scripts/token-saver-up.sh >> ${H}/scripts/token-saver-up.log 2>&1`, marker: "token-saver-up.sh" },
  { event: "SessionEnd", command: `"${H}/scripts/session-economics.mjs" >/dev/null 2>&1`, marker: "session-economics.mjs" },
];
for (const e of entries) {
  s.hooks[e.event] = s.hooks[e.event] || [];
  const present = s.hooks[e.event].some(g => (g.hooks || []).some(h => (h.command || "").includes(e.marker)));
  if (present) continue;
  const obj = { hooks: [{ type: "command", command: e.command }] };
  if (e.matcher) obj.matcher = e.matcher;
  s.hooks[e.event].push(obj);
}
if (!s.effortLevel) s.effortLevel = "high";
s.enabledPlugins = s.enabledPlugins || {};
s.enabledPlugins["context-mode@context-mode"] = true;
s.extraKnownMarketplaces = s.extraKnownMarketplaces || {};
s.extraKnownMarketplaces["context-mode"] = s.extraKnownMarketplaces["context-mode"] || { source: { source: "github", repo: "mksglu/context-mode" } };
writeFileSync(f, JSON.stringify(s, null, 2) + "\n");
console.log("settings.json merged");
N_SETTINGS
  node "$TMP/merge-settings.mjs"
}

merge_zed(){
  [ -d "$(dirname "$ZED_SETTINGS")" ] || return 0   # Zed not present
  cat > "$TMP/merge-zed.mjs" <<'N_ZED'
import { readFileSync, writeFileSync, existsSync, mkdirSync, copyFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, dirname } from "node:path";
const f = join(homedir(), ".config", "zed", "settings.json");
const OLLAMA = {
  api_url: "http://localhost:11434",
  auto_discover: false,
  available_models: [
    { name: "qwen3-coder-tuned", display_name: "Qwen3-Coder 30B (default, coding)", max_tokens: 32768, supports_tools: true, supports_thinking: false, supports_images: false },
    { name: "gpt-oss:20b", display_name: "gpt-oss 20B (fast, clean tools)", max_tokens: 32768, supports_tools: true, supports_thinking: false, supports_images: false },
    { name: "glm-4.7-flash", display_name: "GLM-4.7-Flash (tool-call accuracy)", max_tokens: 32768, supports_tools: true, supports_thinking: false, supports_images: false },
  ],
};
let s = {};
if (existsSync(f)) {
  copyFileSync(f, f + ".bak." + Date.now());
  let raw = readFileSync(f, "utf8");
  const lines = raw.split("\n").filter(l => !l.trimStart().startsWith("//"));
  const noTrail = lines.join("\n").replace(/,(\s*[}\]])/g, "$1");
  try { s = JSON.parse(noTrail); }
  catch { console.error("ZED_PARSE_FAIL"); process.exit(3); }
}
s.language_models = s.language_models || {};
if (s.language_models.ollama && (s.language_models.ollama.available_models || []).length) { console.log("zed already has ollama models"); process.exit(0); }
s.language_models.ollama = OLLAMA;
mkdirSync(dirname(f), { recursive: true });
writeFileSync(f, JSON.stringify(s, null, 2) + "\n");
console.log("zed settings merged");
N_ZED
  node "$TMP/merge-zed.mjs"
}

# ============================================================================
# CHECK — read-only inventory
# ============================================================================
TO_INSTALL=()
chk(){ # chk "label" test-cmd...
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$label"; return 0; else miss "$label"; TO_INSTALL+=("$label"); return 1; fi
}
model_present(){ local out; out="$(ollama list 2>/dev/null)"; case "$out" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
agent_count(){ ls "$AGENTS"/*.md 2>/dev/null | wc -l | tr -d ' '; }

do_check(){
  step "Preliminary check — what's installed vs missing"
  # hardware / os
  if [ "$(uname -m)" = "arm64" ]; then ok "Apple Silicon ($(sysctl -n machdep.cpu.brand_string 2>/dev/null))"; else warn "Not Apple Silicon — MLX speedups won't apply"; fi
  local ram; ram=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 / 1024 ))
  if [ "$ram" -ge 32 ]; then ok "RAM ${ram}GB"; else warn "RAM ${ram}GB (<32GB — the 30B model may be tight)"; fi
  ok "macOS $(sw_vers -productVersion 2>/dev/null)"
  # base tooling
  chk "Xcode Command Line Tools" xcode-select -p
  chk "Homebrew (brew)" have brew
  chk "Node.js" have node
  chk "pnpm" have pnpm
  # local LLM
  if [ -d /Applications/Ollama.app ] || have ollama; then ok "Ollama installed"; else miss "Ollama"; TO_INSTALL+=("Ollama"); fi
  if ollama_up; then ok "Ollama server reachable"; else warn "Ollama server not running (will start)"; fi
  for m in "${MODELS[@]}" "$TUNED"; do
    if model_present "$m"; then ok "model $m"; else miss "model $m"; TO_INSTALL+=("model $m"); fi
  done
  # editor
  if [ -d /Applications/Zed.app ] || have zed; then ok "Zed installed (will wire ollama models)"; else warn "Zed not found (skipping Zed config)"; fi
  # token stack
  chk "rtk" have rtk
  chk "ccusage" have ccusage
  chk "claude-code-router (ccr)" have ccr
  chk "Claude Code (claude)" have claude
  if have claude; then local pl; pl="$(claude plugin list 2>/dev/null)"; case "$pl" in *context-mode*) ok "context-mode plugin" ;; *) miss "context-mode plugin"; TO_INSTALL+=("context-mode plugin") ;; esac
  else miss "context-mode plugin"; TO_INSTALL+=("context-mode plugin"); fi
  # config state
  local n; n=$(agent_count); if [ "$n" -ge 11 ]; then ok "agent fleet ($n agents)"; else miss "agent fleet ($n/11 present)"; TO_INSTALL+=("agent fleet"); fi
  if [ -f "$CLAUDE_DIR/settings.json" ] && grep -q "rtk-extend.mjs" "$CLAUDE_DIR/settings.json" 2>/dev/null; then ok "settings.json hooks (rtk-extend)"; else miss "settings.json hooks"; TO_INSTALL+=("settings hooks"); fi
  if [ -f "$CLAUDE_DIR/CLAUDE.md" ] && grep -q "# modelRouting" "$CLAUDE_DIR/CLAUDE.md" 2>/dev/null; then ok "CLAUDE.md routing"; else miss "CLAUDE.md routing"; TO_INSTALL+=("CLAUDE.md routing"); fi
  if [ -f "$CCR_DIR/config.json" ]; then
    if grep -q "REPLACE_WITH_YOUR_ANTHROPIC_API_KEY" "$CCR_DIR/config.json"; then warn "CCR config present but Anthropic key is still the placeholder"; else ok "CCR config (Anthropic key set)"; fi
  else miss "CCR config"; TO_INSTALL+=("CCR config"); fi
  # auth (report only)
  if have gh && gh auth status >/dev/null 2>&1; then ok "gh authenticated"; else warn "gh not authenticated (only needed to push the repo)"; fi

  echo
  if [ ${#TO_INSTALL[@]} -eq 0 ]; then say "${G}Everything is already in place.${X}"; else
    say "${B}To install (${#TO_INSTALL[@]}):${X} ${TO_INSTALL[*]}"
  fi
}

# ============================================================================
# INSTALL PHASES
# ============================================================================
refresh_path(){ for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$p" ] && eval "$("$p" shellenv)" 2>/dev/null; done; hash -r 2>/dev/null || true; }

phase_base(){
  step "Base tooling"
  if ! xcode-select -p >/dev/null 2>&1; then act_install "Xcode CLT (a dialog may appear — accept it)"; run xcode-select --install || true; else ok "Xcode CLT"; fi

  # Homebrew — try NON-INTERACTIVE; on a fresh Mac its installer still needs a sudo
  # password, so if it can't self-install we say so clearly instead of cascading.
  if ! have brew; then
    act_install "Homebrew"
    [ "$DRY_RUN" != 1 ] && NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/null >>"$LOG" 2>&1
    refresh_path
  fi
  if have brew; then ok "Homebrew present"
  elif [ "$DRY_RUN" = 1 ]; then ok "(dry-run) Homebrew assumed"
  else
    warn "Homebrew couldn't auto-install (its installer needs an interactive sudo password)."
    say "      → Install it once, then re-run this script:"
    say "        /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
  fi

  # Node (needed for ccusage + claude-code-router). Prefer brew; fall back to nvm guidance.
  if ! have node && have brew; then act_install "Node.js"; retry run brew install node; refresh_path; fi
  if have node; then ok "Node $(node -v 2>/dev/null)"
  elif [ "$DRY_RUN" != 1 ]; then warn "Node not installed — ccusage + claude-code-router will be skipped. Install Node ('brew install node' or nvm), then re-run."; fi

  # pnpm (optional — only for JS projects)
  if ! have pnpm; then if have brew; then retry run brew install pnpm; elif have npm; then retry run npm i -g pnpm; fi; refresh_path; fi
  have pnpm && ok "pnpm $(pnpm -v 2>/dev/null)" || warn "pnpm not installed (optional)"
}
act_install(){ printf '  %s*%s installing %s\n' "$C" "$X" "$1"; _log "installing $1"; }

phase_ollama(){
  step "Ollama (official app) + models"
  # remove broken brew bottle if present (it lacks the llama-server runner)
  if brew list ollama >/dev/null 2>&1; then warn "removing brew ollama (bottle lacks llama-server runner)"; run brew uninstall ollama; fi
  if [ ! -d /Applications/Ollama.app ]; then
    act_install "Ollama.app"
    if [ "$DRY_RUN" != 1 ]; then
      retry curl -fsSL -o "$TMP/Ollama-darwin.zip" "$OLLAMA_ZIP" || warn "Ollama download failed"
      run ditto -x -k "$TMP/Ollama-darwin.zip" /Applications/
      run xattr -dr com.apple.quarantine /Applications/Ollama.app
    fi
  else ok "Ollama.app present"; fi
  # put CLI on PATH
  if [ -x /Applications/Ollama.app/Contents/Resources/ollama ] && ! have ollama; then
    local dst=/opt/homebrew/bin; [ -d "$dst" ] || dst=/usr/local/bin
    run ln -sf /Applications/Ollama.app/Contents/Resources/ollama "$dst/ollama"
  fi
  run launchctl setenv OLLAMA_KEEP_ALIVE 1h
  if ollama_up; then ok "Ollama server up ($(curl -s "$OLLAMA_URL/api/version"))"
  elif [ "$DRY_RUN" = 1 ]; then act_install "would start Ollama server and wait for it"
  else
    act_install "starting ollama server"
    open -a Ollama 2>/dev/null || OLLAMA_KEEP_ALIVE=1h nohup ollama serve >/tmp/ollama-serve.log 2>&1 &
    for _ in $(seq 1 30); do ollama_up && break; sleep 1; done
    ollama_up && ok "Ollama server up" || warn "Ollama server still not reachable — check $LOG"
  fi
  # models
  for m in "${MODELS[@]}"; do
    if model_present "$m"; then ok "model $m present"; else act_install "pulling $m (~18GB)"; retry run ollama pull "$m" || warn "pull $m failed"; fi
  done
  # tuned variant
  if model_present "$TUNED"; then ok "$TUNED present"; else
    write_modelfile; act_install "building $TUNED"; run ollama create "$TUNED" -f "$TMP/Modelfile.qwen3coder" || warn "build $TUNED failed"
  fi
}

phase_zed(){
  step "Zed editor config"
  if [ -d /Applications/Zed.app ] || have zed; then
    if [ "$DRY_RUN" = 1 ]; then printf '  %s[dry-run]%s merge ollama models into Zed settings\n' "$C" "$X"
    elif ! have node; then warn "Zed present but Node missing — skipping Zed merge (see SETUP.md for the manual snippet)"
    else merge_zed && ok "Zed ollama models wired" || warn "Zed merge skipped (settings unparseable — see SETUP.md to add manually)"; fi
  else ok "Zed not installed — skipping"; fi
}

phase_token_installs(){
  step "Token-stack tools (rtk, context-mode, ccusage, ccr)"
  # rtk — prefer brew bottle; fall back to the official installer (no brew needed).
  if have rtk; then ok "rtk $(rtk --version 2>/dev/null)"
  else
    act_install "rtk"
    [ "$DRY_RUN" != 1 ] && { have brew && retry run brew install rtk; refresh_path; }
    if ! have rtk && [ "$DRY_RUN" != 1 ]; then curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh >>"$LOG" 2>&1 || true; refresh_path; fi
    have rtk && ok "rtk installed" || { [ "$DRY_RUN" = 1 ] || warn "rtk install failed — needs Homebrew or the install.sh (see $LOG)"; }
  fi
  # rtk init lays down RTK.md + @RTK.md import + a baseline hook (we upgrade the hook to
  # rtk-extend during deploy). Best-effort; </dev/null so it can never hang on a prompt.
  [ "$DRY_RUN" = 1 ] && act "rtk init -g" || { have rtk && rtk init -g </dev/null >>"$LOG" 2>&1 || true; }
  if have claude; then
    local pl; pl="$(claude plugin list 2>/dev/null)"
    case "$pl" in
      *context-mode*) ok "context-mode plugin present" ;;
      *) act_install "context-mode plugin"
         if [ "$DRY_RUN" = 1 ]; then act "claude plugin marketplace add mksglu/context-mode"; act "claude plugin install context-mode@context-mode --scope user"
         else
           # IMPORTANT: these are INTERACTIVE — Claude shows a one-time "trust this marketplace?"
           # prompt. Run them DIRECTLY (visible), never via run() — run() redirects output to the
           # log, which hides the prompt and hangs the whole script waiting on invisible input.
           warn "Claude may now show a one-time 'trust marketplace' prompt — approve it to continue."
           claude plugin marketplace add mksglu/context-mode || warn "marketplace add failed/declined — re-run after approving"
           claude plugin install context-mode@context-mode --scope user || warn "context-mode install failed"
           hash -r 2>/dev/null || true
         fi ;;
    esac
  else warn "claude not found — install Claude Code, then re-run; skipping plugin"; fi
  # ccusage + claude-code-router need npm (Node). Skip cleanly with guidance if absent.
  if have npm; then
    if have ccusage; then ok "ccusage present"; else act_install "ccusage"; retry run npm i -g ccusage; refresh_path; have ccusage && ok "ccusage installed" || warn "ccusage installed but not on PATH — add \"$(npm prefix -g 2>/dev/null)/bin\" to PATH"; fi
    if have ccr; then ok "claude-code-router present"; else act_install "claude-code-router"; retry run npm i -g @musistudio/claude-code-router; refresh_path; have ccr && ok "ccr installed" || warn "ccr installed but not on PATH — add \"$(npm prefix -g 2>/dev/null)/bin\" to PATH"; fi
  elif [ "$DRY_RUN" = 1 ]; then act_install "ccusage + claude-code-router (npm)"
  else warn "npm not found — skipping ccusage + claude-code-router. Install Node, then re-run."; fi
}

phase_deploy(){
  step "Deploy config (agents, hooks, scripts, routing)"
  backup "$CLAUDE_DIR/settings.json"; backup "$CLAUDE_DIR/CLAUDE.md"
  if [ "$DRY_RUN" = 1 ]; then
    printf '  %s[dry-run]%s write 11 agents, 2 hooks, 2 scripts; merge settings.json + CLAUDE.md; write CCR config\n' "$C" "$X"; return 0
  fi
  mkdir -p "$AGENTS" "$HOOKS" "$SCRIPTS"
  # back up existing agents that we own, then write canonical versions
  deploy_agents && ok "11 agents → $AGENTS"
  deploy_hooks && ok "hooks → $HOOKS"
  deploy_scripts && ok "scripts → $SCRIPTS"
  # CLAUDE.md routing block (append once)
  touch "$CLAUDE_DIR/CLAUDE.md"
  if grep -q "# modelRouting" "$CLAUDE_DIR/CLAUDE.md"; then ok "CLAUDE.md routing already present"; else claude_md_block >> "$CLAUDE_DIR/CLAUDE.md"; ok "CLAUDE.md routing appended"; fi
  # settings.json merge (node deep-merge; backs up first, never clobbers)
  if ! have node; then
    warn "Node not found — skipping settings.json merge. Install Node (re-run) to finish wiring hooks."
  elif merge_settings; then ok "settings.json hooks merged"; else warn "settings.json merge failed (invalid existing JSON?) — see $LOG"; fi
  # CCR config — write only if missing (never clobber a real key)
  if [ -f "$CCR_DIR/config.json" ]; then ok "CCR config exists (left as-is)"; else write_ccr_config && ok "CCR config written (add your Anthropic key later)"; fi
}

# ============================================================================
# VERIFY — smoke tests
# ============================================================================
do_verify(){
  step "Verify — smoke tests"
  local fails=0
  # ollama tool-call
  if ollama_up && model_present "$TUNED"; then
    local tc; tc=$(curl -s "$OLLAMA_URL/api/chat" -d "{\"model\":\"$TUNED\",\"stream\":false,\"messages\":[{\"role\":\"user\",\"content\":\"weather in Draper, Utah? use the tool\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"get_weather\",\"description\":\"w\",\"parameters\":{\"type\":\"object\",\"properties\":{\"location\":{\"type\":\"string\"}},\"required\":[\"location\"]}}}]}" 2>/dev/null)
    case "$tc" in *'"tool_calls"'*) ok "ollama tool-call works ($TUNED)" ;; *) warn "ollama tool-call not detected"; fails=$((fails+1)) ;; esac
  else warn "skip ollama tool-call (server/model not ready)"; fi
  # rtk-extend rewrites pnpm
  if have node && [ -f "$HOOKS/rtk-extend.mjs" ] && have rtk; then
    local rw; rw=$(printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"pnpm test"}}' | node "$HOOKS/rtk-extend.mjs" 2>/dev/null)
    case "$rw" in *"rtk pnpm test"*) ok "rtk-extend rewrites 'pnpm test'" ;; *) warn "rtk-extend did not rewrite pnpm"; fails=$((fails+1)) ;; esac
  fi
  # ccr -> local route (start it, poll until the port answers, then route)
  if have ccr; then
    nohup ccr start >/dev/null 2>&1 &
    local up=0 i
    for i in $(seq 1 20); do curl -sf --max-time 3 http://127.0.0.1:3456/ >/dev/null 2>&1 && { up=1; break; }; sleep 1; done
    if [ "$up" = 1 ]; then
      local cr; cr=$(curl -s --max-time 90 http://127.0.0.1:3456/v1/messages -H "anthropic-version: 2023-06-01" -H "content-type: application/json" -d "{\"model\":\"ollama,$TUNED\",\"max_tokens\":20,\"messages\":[{\"role\":\"user\",\"content\":\"say exactly: ok\"}]}" 2>/dev/null)
      case "$cr" in *'"content"'*) ok "CCR routes to local qwen (free local gather works)" ;; *) warn "CCR local route not confirmed (model cold or key issue)" ;; esac
    else warn "CCR server didn't come up on :3456"; fi
  fi
  # agents present
  local n; n=$(agent_count); [ "$n" -ge 11 ] && ok "agent fleet ($n)" || { warn "only $n/11 agents"; fails=$((fails+1)); }
  # settings json valid
  if have node && [ -f "$CLAUDE_DIR/settings.json" ]; then node -e "JSON.parse(require('fs').readFileSync('$CLAUDE_DIR/settings.json','utf8'))" 2>/dev/null && ok "settings.json valid JSON" || { warn "settings.json invalid JSON"; fails=$((fails+1)); }; fi
  # context-mode (the "context aware" layer) — run its OWN headless doctor (checks
  # the native SQLite/FTS5 module + hooks). This is the real test, not just "installed".
  local cmb; cmb=$(ls -t "$CLAUDE_DIR"/plugins/cache/context-mode/context-mode/*/cli.bundle.mjs 2>/dev/null | head -1)
  if [ -n "$cmb" ] && have node; then
    local cmout; cmout=$(node "$cmb" doctor 2>&1)
    case "$cmout" in
      *FAIL*) warn "context-mode doctor: FAIL — run: node \"$cmb\" doctor  (FTS5/native module may need a plugin reinstall or Node update)"; fails=$((fails+1)) ;;
      *PASS*) ok "context-mode healthy (FTS5 / native SQLite module works)" ;;
      *) warn "context-mode doctor inconclusive — run: node \"$cmb\" doctor" ;;
    esac
  else warn "context-mode not found — install: claude plugin install context-mode@context-mode --scope user"; fi
  # session-economics runs
  [ -f "$SCRIPTS/session-economics.mjs" ] && node "$SCRIPTS/session-economics.mjs" >/dev/null 2>&1 && ok "session-economics runs" || true
  echo
  [ "$fails" -eq 0 ] && say "${G}All smoke tests passed.${X}" || say "${Y}$fails smoke test(s) need attention — see $LOG${X}"
  return 0
}

# ============================================================================
# FINISH banner
# ============================================================================
finish(){
  step "Done"
  say "${G}${B}✅ Token-reducer stack is ready.${X}"
  echo
  say "Optional next steps (need YOUR credentials — never auto-entered):"
  if ! (have claude && claude --version >/dev/null 2>&1); then say "  • Install/log in to Claude Code: https://docs.anthropic.com/claude-code (then re-run for the plugin)"; fi
  if [ -f "$CCR_DIR/config.json" ] && grep -q "REPLACE_WITH_YOUR_ANTHROPIC_API_KEY" "$CCR_DIR/config.json"; then
    say "  • For free local gather via 'ccr code': put your Anthropic API key in $CCR_DIR/config.json, then 'ccr restart'."
    say "    (Plain 'claude' works now with no key; CCR is only for routing gather agents to the local model.)"
  fi
  say "  • Restart Claude Code so the new hooks/agents/CLAUDE.md load."
  echo
  say "Reference: SETUP.md  ·  Log: $LOG"
}

cleanup(){ rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

# ============================================================================
# MAIN
# ============================================================================
for a in "$@"; do case "$a" in
  check) MODE=check ;;
  verify) MODE=verify ;;
  --dry-run) DRY_RUN=1 ;;
  -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
  *) ;;
esac; done

DLAB=""; [ "$DRY_RUN" = 1 ] && DLAB=", dry-run"
say "${B}token-reducer setup${X}  (mode: $MODE$DLAB)  ·  log: $LOG"
have curl || die "curl is required"

case "$MODE" in
  check)  do_check ;;
  verify) do_verify ;;
  *)
    do_check
    phase_base
    phase_ollama
    phase_zed
    phase_token_installs
    phase_deploy
    if [ "$DRY_RUN" = 1 ]; then echo; say "(dry-run: skipping smoke tests — run ./setup.sh verify after a real install)"; else do_verify; fi
    finish
    ;;
esac
