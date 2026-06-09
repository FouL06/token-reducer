#!/usr/bin/env bash
# ============================================================================
# token-reducer — LINUX setup (full Claude Code stack). Companion to setup.sh.
#
#   ./setup-linux.sh           # check → install missing → deploy → verify → ready
#   ./setup-linux.sh check     # read-only inventory
#   ./setup-linux.sh verify    # smoke tests only
#   ./setup-linux.sh --dry-run # print actions, change nothing
#
# Reuses setup.sh for the cross-platform pieces (the 11 agents, hooks, CCR config,
# CLAUDE.md, settings merge, verify) and overrides only the platform layer:
#   - package manager: apt / dnf / pacman / zypper (auto-detected)
#   - Ollama via the official install.sh (systemd service on Linux)
#   - Linux service handling in the SessionStart warm-up script
# NOTE: written for Linux; syntax-checked but verify on your distro (run `check` first).
# Package installs use sudo — you'll see its password prompt (it is NOT hidden).
# ============================================================================
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
[ -f "$DIR/setup.sh" ] || { echo "setup-linux.sh needs setup.sh alongside it (clone the whole repo)."; exit 1; }
# Import all shared functions + constants from setup.sh WITHOUT running its mac main.
TR_SOURCE_ONLY=1 . "$DIR/setup.sh"

# ---- package manager --------------------------------------------------------
PKG=""
for m in apt-get dnf pacman zypper; do have "$m" && { PKG="$m"; break; }; done
pkg_update_done=0
pkg_install(){ # visible (sudo prompt must NOT be hidden); honors --dry-run
  [ "$DRY_RUN" = 1 ] && { act "install: $*"; return 0; }
  case "$PKG" in
    apt-get) [ "$pkg_update_done" = 1 ] || { sudo apt-get update -y; pkg_update_done=1; }; sudo apt-get install -y "$@" ;;
    dnf)     sudo dnf install -y "$@" ;;
    pacman)  sudo pacman -S --needed --noconfirm "$@" ;;
    zypper)  sudo zypper install -y "$@" ;;
    *) warn "no supported package manager (apt/dnf/pacman/zypper) — install manually: $*"; return 1 ;;
  esac
}

# ---- CHECK (Linux inventory) ------------------------------------------------
do_check(){
  step "Preliminary check — what's installed vs missing"
  ok "arch $(uname -m) · $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}")"
  local ramkb; ramkb=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
  local ramgb=$(( ramkb / 1024 / 1024 )); [ "$ramgb" -ge 16 ] && ok "RAM ${ramgb}GB" || warn "RAM ${ramgb}GB (the 30B model wants 24GB+ system RAM or a big GPU)"
  [ -n "$PKG" ] && ok "package manager: $PKG" || { miss "package manager"; TO_INSTALL+=("a package manager"); }
  have nvidia-smi && ok "NVIDIA GPU present (Ollama will use CUDA)" || warn "no nvidia-smi (Ollama will run on CPU unless ROCm/CUDA is set up)"
  chk "curl" have curl; chk "git" have git
  chk "Node.js" have node; chk "npm" have npm
  if have ollama; then ok "Ollama installed"; else miss "Ollama"; TO_INSTALL+=("Ollama"); fi
  if ollama_up; then ok "Ollama server reachable"; else warn "Ollama server not running (will start)"; fi
  for m in "${MODELS[@]}" "$TUNED"; do model_present "$m" && ok "model $m" || { miss "model $m"; TO_INSTALL+=("model $m"); }; done
  { have zed || [ -d "$HOME/.config/zed" ]; } && ok "Zed present (will wire ollama models)" || warn "Zed not found (skipping Zed config)"
  chk "rtk" have rtk; chk "ccusage" have ccusage; chk "claude-code-router (ccr)" have ccr; chk "Claude Code (claude)" have claude
  if have claude; then local pl; pl="$(claude plugin list 2>/dev/null)"; case "$pl" in *context-mode*) ok "context-mode plugin" ;; *) miss "context-mode plugin"; TO_INSTALL+=("context-mode plugin") ;; esac
  else miss "context-mode plugin"; TO_INSTALL+=("context-mode plugin"); fi
  local n; n=$(agent_count); [ "$n" -ge 11 ] && ok "agent fleet ($n)" || { miss "agent fleet ($n/11)"; TO_INSTALL+=("agent fleet"); }
  [ -f "$CLAUDE_DIR/settings.json" ] && grep -q rtk-extend.mjs "$CLAUDE_DIR/settings.json" 2>/dev/null && ok "settings.json hooks" || { miss "settings.json hooks"; TO_INSTALL+=("settings hooks"); }
  [ -f "$CLAUDE_DIR/CLAUDE.md" ] && grep -q "# modelRouting" "$CLAUDE_DIR/CLAUDE.md" 2>/dev/null && ok "CLAUDE.md routing" || { miss "CLAUDE.md routing"; TO_INSTALL+=("CLAUDE.md routing"); }
  if [ -f "$CCR_DIR/config.json" ]; then grep -q REPLACE_WITH_YOUR_ANTHROPIC_API_KEY "$CCR_DIR/config.json" && warn "CCR config present (Anthropic key still placeholder)" || ok "CCR config"; else miss "CCR config"; TO_INSTALL+=("CCR config"); fi
  echo
  [ ${#TO_INSTALL[@]} -eq 0 ] && say "${G}Everything is already in place.${X}" || say "${B}To install (${#TO_INSTALL[@]}):${X} ${TO_INSTALL[*]}"
}

# ---- base tooling -----------------------------------------------------------
phase_base(){
  step "Base tooling ($PKG)"
  [ -n "$PKG" ] || { warn "no supported package manager — install curl, git, node, npm manually, then re-run"; return 0; }
  have curl || pkg_install curl ca-certificates
  have git  || pkg_install git
  if ! have node || ! have npm; then
    act_install "Node.js + npm"
    case "$PKG" in
      apt-get) pkg_install nodejs npm ;;
      dnf)     pkg_install nodejs npm ;;
      pacman)  pkg_install nodejs npm ;;
      zypper)  pkg_install nodejs npm ;;
    esac
    refresh_path
  fi
  have node && ok "Node $(node -v 2>/dev/null)" || warn "Node still missing — ccusage/ccr/context-mode need it; install Node 20+, then re-run."
  if ! have pnpm && have npm; then run npm i -g pnpm; refresh_path; fi
  have pnpm && ok "pnpm $(pnpm -v 2>/dev/null)" || warn "pnpm not installed (optional)"
}

# ---- Ollama (official install.sh + systemd) ---------------------------------
phase_ollama(){
  step "Ollama + models"
  if ! have ollama; then
    act_install "Ollama (official install.sh — may prompt for sudo)"
    [ "$DRY_RUN" = 1 ] || { curl -fsSL https://ollama.com/install.sh | sh; refresh_path; }
  else ok "ollama present"; fi
  # keep-alive via systemd drop-in (best-effort; visible sudo)
  if [ "$DRY_RUN" != 1 ] && have systemctl && systemctl list-unit-files 2>/dev/null | grep -q '^ollama.service'; then
    sudo mkdir -p /etc/systemd/system/ollama.service.d 2>/dev/null && \
      printf '[Service]\nEnvironment="OLLAMA_KEEP_ALIVE=1h"\n' | sudo tee /etc/systemd/system/ollama.service.d/keepalive.conf >/dev/null 2>&1 && \
      sudo systemctl daemon-reload 2>/dev/null && sudo systemctl restart ollama 2>/dev/null && ok "OLLAMA_KEEP_ALIVE=1h (systemd)" || warn "couldn't set keep-alive drop-in (non-fatal)"
  fi
  # ensure server up
  if ollama_up; then ok "Ollama server up ($(curl -s "$OLLAMA_URL/api/version"))"
  elif [ "$DRY_RUN" = 1 ]; then act_install "would start Ollama and wait"
  else
    have systemctl && sudo systemctl enable --now ollama 2>/dev/null || OLLAMA_KEEP_ALIVE=1h nohup ollama serve >/tmp/ollama-serve.log 2>&1 &
    for _ in $(seq 1 30); do ollama_up && break; sleep 1; done
    ollama_up && ok "Ollama server up" || warn "Ollama server not reachable — check 'systemctl status ollama' / $LOG"
  fi
  for m in "${MODELS[@]}"; do model_present "$m" && ok "model $m present" || { act_install "pulling $m (~18GB)"; retry run ollama pull "$m" || warn "pull $m failed"; }; done
  if model_present "$TUNED"; then ok "$TUNED present"; else write_modelfile; act_install "building $TUNED"; run ollama create "$TUNED" -f "$TMP/Modelfile.qwen3coder" || warn "build $TUNED failed"; fi
}

# ---- Zed (same config path on Linux) ----------------------------------------
phase_zed(){
  step "Zed editor config"
  if have zed || [ -d "$HOME/.config/zed" ]; then
    if [ "$DRY_RUN" = 1 ]; then act "merge ollama models into Zed settings"
    elif ! have node; then warn "Zed present but Node missing — skipping Zed merge (see SETUP.md snippet)"
    else merge_zed && ok "Zed ollama models wired" || warn "Zed merge skipped (unparseable settings — add manually)"; fi
  else ok "Zed not installed — skipping"; fi
}

# ---- token-stack installs (rtk via installer, not brew) ---------------------
phase_token_installs(){
  step "Token-stack tools (rtk, context-mode, ccusage, ccr)"
  if have rtk; then ok "rtk $(rtk --version 2>/dev/null)"
  else
    act_install "rtk"
    if [ "$DRY_RUN" != 1 ]; then curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh >>"$LOG" 2>&1 || true; refresh_path; fi
    have rtk && ok "rtk installed" || { [ "$DRY_RUN" = 1 ] || warn "rtk install failed — see https://github.com/rtk-ai/rtk (or 'cargo install --git')"; }
  fi
  [ "$DRY_RUN" = 1 ] && act "rtk init -g" || { have rtk && rtk init -g </dev/null >>"$LOG" 2>&1 || true; }
  # context-mode plugin — INTERACTIVE trust prompt; run visibly (never hidden).
  if have claude; then
    local pl; pl="$(claude plugin list 2>/dev/null)"
    case "$pl" in
      *context-mode*) ok "context-mode plugin present" ;;
      *) act_install "context-mode plugin"
         if [ "$DRY_RUN" = 1 ]; then act "claude plugin marketplace add + install"
         else warn "Claude may show a one-time 'trust marketplace' prompt — approve it."
           claude plugin marketplace add mksglu/context-mode || warn "marketplace add failed/declined"
           claude plugin install context-mode@context-mode --scope user || warn "context-mode install failed"; hash -r 2>/dev/null || true; fi ;;
    esac
  else warn "claude not found — install Claude Code, then re-run; skipping plugin"; fi
  if have npm; then
    have ccusage && ok "ccusage present" || { act_install "ccusage"; retry run npm i -g ccusage; refresh_path; have ccusage && ok "ccusage installed" || warn "ccusage not on PATH — add \"$(npm prefix -g 2>/dev/null)/bin\""; }
    have ccr && ok "ccr present" || { act_install "claude-code-router"; retry run npm i -g @musistudio/claude-code-router; refresh_path; have ccr && ok "ccr installed" || warn "ccr not on PATH — add \"$(npm prefix -g 2>/dev/null)/bin\""; }
  elif [ "$DRY_RUN" = 1 ]; then act "ccusage + claude-code-router (npm)"
  else warn "npm not found — skipping ccusage + claude-code-router. Install Node, then re-run."; fi
}

# ---- Linux warm-up script (overrides the macOS one) -------------------------
deploy_scripts(){
  mkdir -p "$SCRIPTS"
  cat > "$SCRIPTS/token-saver-up.sh" <<'S_LINUX'
#!/usr/bin/env bash
# token-saver-up.sh (Linux) — ensure Ollama + claude-code-router are up, warm the model.
set -u
OLLAMA_URL="http://localhost:11434"; MODEL="qwen3-coder-tuned"; CCR_CONFIG="$HOME/.claude-code-router/config.json"
if [ "${1:-}" = "--warm-only" ]; then
  for _ in $(seq 1 60); do curl -sf "$OLLAMA_URL/api/version" >/dev/null 2>&1 && break; sleep 1; done
  curl -s "$OLLAMA_URL/api/generate" -d "{\"model\":\"$MODEL\",\"prompt\":\"ok\",\"stream\":false,\"keep_alive\":\"1h\"}" >/dev/null 2>&1
  exit 0
fi
ok(){ printf '  [ok]   %s\n' "$1"; }; act(){ printf '  [..]   %s\n' "$1"; }; warn(){ printf '  [warn] %s\n' "$1"; }
echo "token-saver-up @ $(date '+%Y-%m-%d %H:%M:%S')"
if curl -sf "$OLLAMA_URL/api/version" >/dev/null 2>&1; then ok "ollama running"
else act "starting ollama"; systemctl --user start ollama 2>/dev/null || OLLAMA_KEEP_ALIVE=1h nohup ollama serve >/tmp/ollama-serve.log 2>&1 & fi
if command -v ccr >/dev/null 2>&1; then ccr status >/dev/null 2>&1 && ok "claude-code-router running" || { act "starting ccr"; nohup ccr start >/dev/null 2>&1 & }; fi
act "warming $MODEL (background, keep_alive 1h)"; nohup bash "$0" --warm-only >/dev/null 2>&1 &
[ -f "$CCR_CONFIG" ] && grep -q "REPLACE_WITH_YOUR_ANTHROPIC_API_KEY" "$CCR_CONFIG" && warn "CCR cloud key not set — add your Anthropic key + 'ccr restart' for free local gather via 'ccr code'."
echo "token-saver-up: dispatched."
S_LINUX
  cat > "$SCRIPTS/session-economics.mjs" <<'S_ECON'
#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { appendFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, dirname } from "node:path";
const LOG = join(homedir(), ".claude", "scripts", "session-economics.log");
const today = new Date().toISOString().slice(0, 10);
const BIN = dirname(process.execPath);
function tryRun(file, args){ try { return execFileSync(file, args, { encoding:"utf8", timeout:60000, stdio:["ignore","pipe","ignore"] }); } catch { return ""; } }
let todaySpend="n/a", allSpend="n/a";
const raw = tryRun(join(BIN,"ccusage"),["--json"]) || tryRun("ccusage",["--json"]);
try { const d=JSON.parse(raw); allSpend="$"+(d.totals?.totalCost ?? 0).toFixed(2);
  const t=(d.daily||[]).filter(x=>String(x.period).startsWith(today)).reduce((s,x)=>s+(x.totalCost||0),0); todaySpend="$"+t.toFixed(2); } catch {}
let saved="n/a", pct="";
const g = tryRun("rtk",["gain"]); const m = g.match(/Tokens saved:\s*([\d.]+[KMB]?)\s*\(([\d.]+%)\)/i);
if (m){ saved=m[1]; pct=m[2]; }
console.log("── session economics ──");
console.log(`  spend   today: ${todaySpend}   all-time: ${allSpend}`);
console.log(`  rtk saved: ${saved}${pct?` (${pct})`:""}`);
try { appendFileSync(LOG, `${new Date().toISOString()} | spend today ${todaySpend} (all-time ${allSpend}) | rtk saved ${saved} ${pct}\n`); } catch {}
S_ECON
  chmod +x "$SCRIPTS/token-saver-up.sh" "$SCRIPTS/session-economics.mjs" 2>/dev/null || true
}

# ============================================================================
# MAIN (Linux)
# ============================================================================
for a in "$@"; do case "$a" in
  check) MODE=check ;; verify) MODE=verify ;; --dry-run) DRY_RUN=1 ;;
  -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
esac; done
DLAB=""; [ "$DRY_RUN" = 1 ] && DLAB=", dry-run"
say "${B}token-reducer setup (Linux)${X}  (mode: $MODE$DLAB)  ·  log: $LOG"
have curl || die "curl is required (install it via your package manager first)"
case "$MODE" in
  check)  do_check ;;
  verify) do_verify ;;
  *)
    do_check; phase_base; phase_ollama; phase_zed; phase_token_installs; phase_deploy
    if [ "$DRY_RUN" = 1 ]; then echo; say "(dry-run: skipping smoke tests — run ./setup-linux.sh verify after a real install)"; else do_verify; fi
    finish ;;
esac
