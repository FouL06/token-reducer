#!/usr/bin/env bash
# ============================================================================
# token-reducer — uninstall / cleanup. Reverts what setup.sh did.
#
#   ./uninstall.sh             # CONFIG ONLY: remove agents, hooks, scripts,
#                              #   our settings.json entries, CLAUDE.md blocks,
#                              #   CCR config. Keeps Ollama + models + tools.
#                              #   (use this to recover from a broken state)
#   ./uninstall.sh --models    # also `ollama rm` the 4 pulled models
#   ./uninstall.sh --all        # also remove Ollama.app, rtk, ccr, ccusage,
#                              #   context-mode plugin, RTK.md  (FULL teardown)
#   ./uninstall.sh --restore   # restore newest settings.json/CLAUDE.md backups
#                              #   instead of surgical edits
#   ./uninstall.sh --dry-run   # show what would happen, change nothing
#   ./uninstall.sh --yes       # don't prompt for destructive steps
#
# Always backs up settings.json + CLAUDE.md before editing. Safe to re-run.
# ============================================================================
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -uo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
AGENTS="$CLAUDE_DIR/agents"
HOOKS="$CLAUDE_DIR/hooks"
SCRIPTS="$CLAUDE_DIR/scripts"
CCR_DIR="$HOME/.claude-code-router"
ZED_SETTINGS="$HOME/.config/zed/settings.json"
OUR_AGENTS=(scanner planner reviewer summarizer test-runner doc-retriever extractor tool-caller writer verifier triager)
MODELS=("qwen3-coder:30b" "gpt-oss:20b" "glm-4.7-flash" "qwen3-coder-tuned")
DRY_RUN=0; ASSUME_YES=0; DO_MODELS=0; DO_ALL=0; DO_RESTORE=0

if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; X=$'\e[0m'; else B=; G=; Y=; R=; C=; X=; fi
say(){ printf '%s\n' "$*"; }
step(){ printf '\n%s== %s ==%s\n' "$B" "$*" "$X"; }
ok(){ printf '  %s✓%s %s\n' "$G" "$X" "$*"; }
warn(){ printf '  %s!%s %s\n' "$Y" "$X" "$*"; }
act(){ if [ "$DRY_RUN" = 1 ]; then printf '  %s[dry-run]%s %s\n' "$C" "$X" "$*"; else printf '  %s•%s %s\n' "$C" "$X" "$*"; fi; }
have(){ command -v "$1" >/dev/null 2>&1; }
do_rm(){ [ "$DRY_RUN" = 1 ] && { act "rm $*"; return 0; }; rm -rf "$@" 2>/dev/null; }
backup(){ local f="$1"; [ -f "$f" ] && [ "$DRY_RUN" != 1 ] && cp "$f" "$f.bak.$(date +%s)" 2>/dev/null; return 0; }
confirm(){ # confirm "prompt" — yes if --yes/--dry-run
  [ "$ASSUME_YES" = 1 ] || [ "$DRY_RUN" = 1 ] && return 0
  printf '  %s?%s %s [y/N] ' "$Y" "$X" "$1"; read -r a </dev/tty 2>/dev/null || a=n
  case "$a" in y|Y|yes) return 0 ;; *) return 1 ;; esac
}

for a in "$@"; do case "$a" in
  --models) DO_MODELS=1 ;;
  --all) DO_ALL=1; DO_MODELS=1 ;;
  --restore) DO_RESTORE=1 ;;
  --dry-run) DRY_RUN=1 ;;
  --yes|-y) ASSUME_YES=1 ;;
  -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
esac; done

DLAB=""; [ "$DRY_RUN" = 1 ] && DLAB=" (dry-run)"
say "${B}token-reducer uninstall${X}$DLAB"

# ---- restore-from-backup mode ----------------------------------------------
restore_newest(){ # restore_newest <file>
  local f="$1" newest
  newest=$(ls -t "$f".bak.* 2>/dev/null | head -1)
  if [ -n "$newest" ]; then act "restore $f  ←  $(basename "$newest")"; [ "$DRY_RUN" = 1 ] || cp "$newest" "$f"; ok "restored $f"; else warn "no backup found for $f"; fi
}
if [ "$DO_RESTORE" = 1 ]; then
  step "Restore newest backups"
  restore_newest "$CLAUDE_DIR/settings.json"
  restore_newest "$CLAUDE_DIR/CLAUDE.md"
  say "\n${G}Restored. Restart Claude Code.${X}"
  exit 0
fi

# ---- node surgical remover for settings.json -------------------------------
strip_settings(){
  have node || { warn "node not found — can't surgically edit settings.json (try --restore)"; return 1; }
  local removePlugin="$1"   # 1 = also drop context-mode plugin keys
  REMOVE_PLUGIN="$removePlugin" TR_DIR="$CLAUDE_DIR" node - <<'N_STRIP'
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";
const dir = process.env.TR_DIR;
const f = join(dir, "settings.json");
if (!existsSync(f)) { console.log("no settings.json"); process.exit(0); }
let s; try { s = JSON.parse(readFileSync(f, "utf8")); } catch { console.error("settings.json invalid — use --restore"); process.exit(2); }
const MARKERS = ["rtk-extend.mjs", "context-mode-cache-heal.mjs", "token-saver-up.sh", "session-economics.mjs"];
if (s.hooks) for (const ev of Object.keys(s.hooks)) {
  if (!Array.isArray(s.hooks[ev])) continue;
  for (const g of s.hooks[ev]) if (Array.isArray(g.hooks)) g.hooks = g.hooks.filter(h => !MARKERS.some(m => (h.command || "").includes(m)));
  s.hooks[ev] = s.hooks[ev].filter(g => (g.hooks || []).length > 0);
  if (s.hooks[ev].length === 0) delete s.hooks[ev];
}
if (s.hooks && Object.keys(s.hooks).length === 0) delete s.hooks;
if (process.env.REMOVE_PLUGIN === "1") {
  if (s.enabledPlugins) { delete s.enabledPlugins["context-mode@context-mode"]; if (!Object.keys(s.enabledPlugins).length) delete s.enabledPlugins; }
  if (s.extraKnownMarketplaces) { delete s.extraKnownMarketplaces["context-mode"]; if (!Object.keys(s.extraKnownMarketplaces).length) delete s.extraKnownMarketplaces; }
}
writeFileSync(f, JSON.stringify(s, null, 2) + "\n");
console.log("settings.json cleaned");
N_STRIP
}

# ---- CONFIG removal (default) ----------------------------------------------
step "Remove token-reducer config"
backup "$CLAUDE_DIR/settings.json"; backup "$CLAUDE_DIR/CLAUDE.md"
# agents
for a in "${OUR_AGENTS[@]}"; do [ -f "$AGENTS/$a.md" ] && { act "remove agent $a"; do_rm "$AGENTS/$a.md"; }; done
ok "agents removed"
# hooks + scripts
do_rm "$HOOKS/rtk-extend.mjs"; [ "$DO_ALL" = 1 ] && do_rm "$HOOKS/context-mode-cache-heal.mjs"
do_rm "$SCRIPTS/token-saver-up.sh" "$SCRIPTS/session-economics.mjs" "$SCRIPTS/token-saver-up.log" "$SCRIPTS/session-economics.log"
ok "hooks + scripts removed"
# settings.json entries (surgical)
act "strip our hook entries from settings.json"
[ "$DRY_RUN" = 1 ] || strip_settings "$DO_ALL" && ok "settings.json hook entries removed" || warn "settings.json not modified"
# CLAUDE.md blocks (everything from our '# modelRouting' onward — appended at end)
if [ -f "$CLAUDE_DIR/CLAUDE.md" ] && grep -q "^# modelRouting$" "$CLAUDE_DIR/CLAUDE.md" 2>/dev/null; then
  act "remove # modelRouting + # tokenLanes blocks from CLAUDE.md"
  if [ "$DRY_RUN" != 1 ]; then
    awk 'BEGIN{f=1} /^# modelRouting$/{f=0} f{print}' "$CLAUDE_DIR/CLAUDE.md" > "$CLAUDE_DIR/CLAUDE.md.tmp$$" && mv "$CLAUDE_DIR/CLAUDE.md.tmp$$" "$CLAUDE_DIR/CLAUDE.md"
    # trim trailing blank lines
    [ -s "$CLAUDE_DIR/CLAUDE.md" ] && perl -0pi -e 's/\n+\z/\n/' "$CLAUDE_DIR/CLAUDE.md" 2>/dev/null
  fi
  ok "CLAUDE.md routing blocks removed"
else ok "CLAUDE.md has no token-reducer blocks"; fi
# CCR config
[ -f "$CCR_DIR/config.json" ] && { backup "$CCR_DIR/config.json"; act "remove CCR config"; do_rm "$CCR_DIR/config.json"; ok "CCR config removed"; }

# ---- MODELS (optional) -----------------------------------------------------
if [ "$DO_MODELS" = 1 ]; then
  step "Remove Ollama models (~50GB)"
  if have ollama && confirm "Delete models ${MODELS[*]}?"; then
    for m in "${MODELS[@]}"; do act "ollama rm $m"; [ "$DRY_RUN" = 1 ] || ollama rm "$m" >/dev/null 2>&1; done
    ok "models removed"
  else warn "skipped model removal"; fi
fi

# ---- FULL teardown (optional) ----------------------------------------------
if [ "$DO_ALL" = 1 ]; then
  step "Full teardown — tools + app"
  # stop services
  have ccr && { act "ccr stop"; [ "$DRY_RUN" = 1 ] || ccr stop >/dev/null 2>&1; }
  act "quit Ollama"; [ "$DRY_RUN" = 1 ] || osascript -e 'quit app "Ollama"' >/dev/null 2>&1
  # context-mode plugin
  if have claude; then act "uninstall context-mode plugin"; [ "$DRY_RUN" = 1 ] || { claude plugin uninstall context-mode@context-mode >/dev/null 2>&1; claude plugin marketplace remove context-mode >/dev/null 2>&1; }; fi
  # npm globals
  for pkg in @musistudio/claude-code-router ccusage; do have npm && { act "npm rm -g $pkg"; [ "$DRY_RUN" = 1 ] || npm rm -g "$pkg" >/dev/null 2>&1; }; done
  # rtk + its files
  if have rtk && confirm "Remove rtk (output compression)?"; then
    act "uninstall rtk"; [ "$DRY_RUN" = 1 ] || brew uninstall rtk >/dev/null 2>&1
    do_rm "$CLAUDE_DIR/RTK.md"
    # drop the @RTK.md import line from CLAUDE.md
    [ "$DRY_RUN" != 1 ] && [ -f "$CLAUDE_DIR/CLAUDE.md" ] && grep -v '^@RTK.md$' "$CLAUDE_DIR/CLAUDE.md" > "$CLAUDE_DIR/CLAUDE.md.tmp$$" && mv "$CLAUDE_DIR/CLAUDE.md.tmp$$" "$CLAUDE_DIR/CLAUDE.md"
  fi
  # Ollama.app + keep-alive env
  if [ -d /Applications/Ollama.app ] && confirm "Delete /Applications/Ollama.app?"; then act "remove Ollama.app"; do_rm /Applications/Ollama.app; fi
  act "unset OLLAMA_KEEP_ALIVE"; [ "$DRY_RUN" = 1 ] || launchctl unsetenv OLLAMA_KEEP_ALIVE 2>/dev/null
  # Zed: note only (don't auto-edit JSONC); point to backup
  [ -f "$ZED_SETTINGS" ] && warn "Zed: remove the language_models.ollama block by hand if desired (backups at $ZED_SETTINGS.bak.*)"
fi

step "Done"
say "${G}${B}✓ token-reducer config removed.${X}"
[ "$DO_ALL" != 1 ] && say "Kept: Ollama + models + rtk/ccr/ccusage/context-mode (use --all to remove those too)."
say "Backups: $CLAUDE_DIR/settings.json.bak.*  ·  $CLAUDE_DIR/CLAUDE.md.bak.*"
say "Restart Claude Code so it reloads clean."
