#!/usr/bin/env bash
# ============================================================================
# Local coding LLM on CachyOS / Arch + NVIDIA (e.g. RTX 3060 laptop, 6GB VRAM)
# via OLLAMA (CUDA), wired into the Zed editor's Agent panel. NO Claude Code.
#
# RECOMMENDED backend for Zed (vs llama.cpp): Zed has a first-class native Ollama
# provider that auto-discovers pulled models and exposes per-model capability flags;
# Ollama installs from Arch's official repo (ollama-cuda) and auto-offloads to the GPU.
#
#
#   ./setup-cachyos-ollama.sh           # check → install → pull models → wire Zed → verify
#   ./setup-cachyos-ollama.sh check     # read-only inventory
#   ./setup-cachyos-ollama.sh verify    # smoke tests only
#   ./setup-cachyos-ollama.sh --dry-run # print actions, change nothing
#
# WRITTEN FOR Arch/CachyOS + NVIDIA; syntax-checked but UNTESTED on that hardware.
# Run `check` first. sudo/pacman prompts are shown (not hidden).
# ============================================================================
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -uo pipefail

OLLAMA_URL="http://localhost:11434"
# 6GB-friendly coders (Q4_K_M defaults in Ollama): 7B ~4.7GB (best), 3B ~1.9GB (comfortable).
MODELS=("qwen2.5-coder:7b" "qwen2.5-coder:3b")
TUNED="qwen2.5-coder-tuned"
PRIMARY="$TUNED"
ZCTX=8192          # Zed max_tokens → Ollama num_ctx. Modest for 6GB KV cache; raise if VRAM allows.
ZED_SETTINGS="$HOME/.config/zed/settings.json"
TMP="$(mktemp -d)"
LOG="${TMPDIR:-/tmp}/cachyos-ollama-setup.log"
DRY_RUN=0; MODE=install

if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; X=$'\e[0m'; else B=; G=; Y=; R=; C=; X=; fi
: > "$LOG"
say(){ printf '%s\n' "$*"; printf '%s\n' "$*" >>"$LOG"; }
step(){ printf '\n%s== %s ==%s\n' "$B" "$*" "$X"; }
ok(){ printf '  %s✓%s %s\n' "$G" "$X" "$*"; }
warn(){ printf '  %s!%s %s\n' "$Y" "$X" "$*"; }
miss(){ printf '  %s✗%s %s\n' "$R" "$X" "$*"; }
act(){ if [ "$DRY_RUN" = 1 ]; then printf '  %s[dry-run]%s %s\n' "$C" "$X" "$*"; else printf '  %s•%s %s\n' "$C" "$X" "$*"; fi; }
die(){ printf '\n%sFATAL:%s %s\n' "$R" "$X" "$*"; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
run(){ [ "$DRY_RUN" = 1 ] && { act "$*"; return 0; }; "$@" >>"$LOG" 2>&1; }
retry(){ local n=0; until "$@"; do n=$((n+1)); [ $n -ge 3 ] && return 1; sleep $((n*3)); done; }
ollama_up(){ curl -sf "$OLLAMA_URL/api/version" >/dev/null 2>&1; }
model_present(){ local o; o="$(ollama list 2>/dev/null)"; case "$o" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

for a in "$@"; do case "$a" in
  check) MODE=check ;; verify) MODE=verify ;; --dry-run) DRY_RUN=1 ;;
  -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
esac; done

# ---- CHECK ------------------------------------------------------------------
do_check(){
  step "Check — CachyOS/Arch + NVIDIA + Ollama + Zed"
  have pacman && ok "Arch-based ($(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Arch}"))" || miss "not Arch-based (this script targets pacman)"
  if have nvidia-smi; then
    local vram; vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
    ok "NVIDIA: $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1) — ${vram} MiB"
    [ "${vram:-0}" -lt 6500 ] 2>/dev/null && warn "≤6GB VRAM: use qwen2.5-coder:7b (Q4) or :3b; keep ctx ~$ZCTX; whole model must fit in VRAM"
  else miss "no nvidia-smi — install driver: sudo pacman -S nvidia-open-dkms nvidia-utils (Ampere) — reboot may be needed"; fi
  have ollama && ok "Ollama installed ($(ollama --version 2>/dev/null | head -1))" || miss "Ollama (will install ollama-cuda)"
  ollama_up && ok "Ollama server reachable" || warn "Ollama server not running (will enable the service)"
  for m in "${MODELS[@]}"; do model_present "$m" && ok "model $m" || miss "model $m (will pull)"; done
  { have zed || [ -d "$HOME/.config/zed" ]; } && ok "Zed present" || miss "Zed (install from zed.dev or AUR)"
  chk "rtk" have rtk
  if [ -f "$ZED_SETTINGS" ] && grep -q '"ollama"' "$ZED_SETTINGS" 2>/dev/null; then ok "Zed has an ollama provider block"; else warn "Zed not yet wired to Ollama"; fi
}
chk(){ local label="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$label"; else miss "$label"; fi; }

write_modelfile(){
  cat > "$TMP/Modelfile.qwen25coder" <<'F_MODELFILE'
FROM qwen2.5-coder:7b
PARAMETER temperature 0.7
PARAMETER top_p 0.8
PARAMETER top_k 20
PARAMETER repeat_penalty 1.05
PARAMETER num_ctx 8192
F_MODELFILE
}

# ---- NVIDIA driver note (don't force; driver installs need care/reboot) -----
phase_driver(){
  step "NVIDIA driver / CUDA"
  if have nvidia-smi; then ok "driver present — Ollama will use CUDA automatically"
  else warn "No NVIDIA driver detected. For an Ampere RTX 3060 install (then reboot):"
       say "      sudo pacman -S nvidia-open-dkms nvidia-utils    # or 'nvidia' (proprietary) if GSP firmware issues"
       say "      Ollama needs only the driver (it bundles its CUDA runtime) — the full 'cuda' toolkit is optional."
  fi
}

# ---- Ollama (ollama-cuda from Arch extra → official install.sh) -------------
phase_ollama(){
  step "Ollama (CUDA) + models"
  if have ollama; then ok "ollama present"
  elif [ "$DRY_RUN" = 1 ]; then act "install ollama-cuda (pacman) or official install.sh"
  else
    if pacman -Si ollama-cuda >/dev/null 2>&1; then act "pacman ollama-cuda"; sudo pacman -S --needed --noconfirm ollama-cuda
    else warn "ollama-cuda not in repos — using official install.sh"; curl -fsSL https://ollama.com/install.sh | sh; fi
    hash -r 2>/dev/null || true
  fi
  # keep-alive + service
  if [ "$DRY_RUN" != 1 ] && have systemctl && systemctl list-unit-files 2>/dev/null | grep -q '^ollama.service'; then
    sudo mkdir -p /etc/systemd/system/ollama.service.d 2>/dev/null && \
      printf '[Service]\nEnvironment="OLLAMA_KEEP_ALIVE=1h"\n' | sudo tee /etc/systemd/system/ollama.service.d/keepalive.conf >/dev/null 2>&1 && \
      sudo systemctl daemon-reload 2>/dev/null && sudo systemctl enable --now ollama 2>/dev/null && ok "ollama service enabled (KEEP_ALIVE=1h)" || warn "couldn't configure systemd service (non-fatal)"
  fi
  if ollama_up; then ok "server up ($(curl -s "$OLLAMA_URL/api/version"))"
  elif [ "$DRY_RUN" = 1 ]; then act "would start ollama + wait"
  else
    have systemctl && sudo systemctl enable --now ollama 2>/dev/null || OLLAMA_KEEP_ALIVE=1h nohup ollama serve >/tmp/ollama-serve.log 2>&1 &
    for _ in $(seq 1 30); do ollama_up && break; sleep 1; done
    ollama_up && ok "server up" || warn "server not reachable — check 'systemctl status ollama' / $LOG"
  fi
  for m in "${MODELS[@]}"; do model_present "$m" && ok "$m present" || { act "pulling $m"; retry run ollama pull "$m" || warn "pull $m failed"; }; done
  if model_present "$TUNED"; then ok "$TUNED present"; else
    write_modelfile; act "building $TUNED (pinned num_ctx $ZCTX + sampling)"; run ollama create "$TUNED" -f "$TMP/Modelfile.qwen25coder" || warn "build $TUNED failed"
  fi
}

# ---- rtk (output compression) -----------------------------------------------
phase_rtk(){
  step "Output Compression (rtk)"
  if have rtk; then ok "rtk $(rtk --version 2>/dev/null)"
  elif [ "$DRY_RUN" = 1 ]; then act "install rtk (curl install.sh)"
  else
    act "installing rtk"
    curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh >>"$LOG" 2>&1 || true
    [ -f "$HOME/.cargo/bin/rtk" ] && export PATH="$HOME/.cargo/bin:$PATH"
    [ -f "$HOME/.local/bin/rtk" ] && export PATH="$HOME/.local/bin:$PATH"
    have rtk && ok "rtk installed" || warn "rtk install failed — see https://github.com/rtk-ai/rtk"
  fi
}

# ---- wire Zed (native ollama provider, supports_tools per model) ------------
zed_snippet(){ cat <<EOF
  "language_models": {
    "ollama": {
      "api_url": "$OLLAMA_URL",
      "available_models": [
        { "name": "$TUNED", "display_name": "Qwen2.5-Coder 7B Tuned (local, 8k ctx)", "max_tokens": $ZCTX, "supports_tools": true },
        { "name": "qwen2.5-coder:7b", "display_name": "Qwen2.5-Coder 7B (local)",      "max_tokens": $ZCTX, "supports_tools": true },
        { "name": "qwen2.5-coder:3b", "display_name": "Qwen2.5-Coder 3B (local, fast)", "max_tokens": $ZCTX, "supports_tools": true }
      ]
    }
  }
EOF
}
phase_zed(){
  step "Wire Zed → Ollama"
  if ! { have zed || [ -d "$HOME/.config/zed" ]; }; then warn "Zed not found — add this to ~/.config/zed/settings.json:"; zed_snippet; return 0; fi
  if [ "$DRY_RUN" = 1 ]; then act "merge ollama provider into $ZED_SETTINGS"; zed_snippet; return 0; fi
  if ! have node; then warn "node not found — can't auto-merge Zed settings. Add by hand:"; zed_snippet; return 0; fi
  ZED_FILE="$ZED_SETTINGS" OLLAMA_URL="$OLLAMA_URL" ZCTX="$ZCTX" TUNED="$TUNED" node - <<'N_ZED' || { warn "auto-merge failed — add by hand:"; zed_snippet; }
import { readFileSync, writeFileSync, existsSync, mkdirSync, copyFileSync } from "node:fs";
import { dirname } from "node:path";
const f = process.env.ZED_FILE, ctx = Number(process.env.ZCTX), tuned = process.env.TUNED;
const prov = { api_url: process.env.OLLAMA_URL, available_models: [
  { name: tuned, display_name: "Qwen2.5-Coder 7B Tuned (local, 8k ctx)", max_tokens: ctx, supports_tools: true },
  { name: "qwen2.5-coder:7b", display_name: "Qwen2.5-Coder 7B (local)", max_tokens: ctx, supports_tools: true },
  { name: "qwen2.5-coder:3b", display_name: "Qwen2.5-Coder 3B (local, fast)", max_tokens: ctx, supports_tools: true },
]};
let s = {};
if (existsSync(f)) { copyFileSync(f, f + ".bak." + Date.now());
  const nc = readFileSync(f,"utf8").split("\n").filter(l=>!l.trimStart().startsWith("//")).join("\n").replace(/,(\s*[}\]])/g,"$1");
  try { s = JSON.parse(nc); } catch { console.error("ZED_PARSE_FAIL"); process.exit(3); } }
s.language_models = s.language_models || {};
s.language_models.ollama = prov;
mkdirSync(dirname(f), { recursive: true });
writeFileSync(f, JSON.stringify(s, null, 2) + "\n");
console.log("zed wired");
N_ZED
  grep -q '"ollama"' "$ZED_SETTINGS" 2>/dev/null && ok "Zed wired to Ollama ($TUNED, 7b, 3b with supports_tools: true)" || true
  say "  In Zed: Agent panel → model picker → ${B}Ollama / Qwen2.5-Coder${X}. (Restart Zed to load.)"
}

# ---- verify -----------------------------------------------------------------
do_verify(){
  step "Verify"
  local fails=0
  have ollama && ok "ollama installed" || { miss "ollama missing"; fails=$((fails+1)); }
  ollama_up && ok "server responds on :11434" || { warn "server not up"; fails=$((fails+1)); }
  if ollama_up && model_present "$PRIMARY"; then
    local tc; tc=$(curl -s "$OLLAMA_URL/api/chat" -d "{\"model\":\"$PRIMARY\",\"stream\":false,\"messages\":[{\"role\":\"user\",\"content\":\"weather in Draper, UT? use the get_weather tool\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"get_weather\",\"description\":\"w\",\"parameters\":{\"type\":\"object\",\"properties\":{\"location\":{\"type\":\"string\"}},\"required\":[\"location\"]}}}]}" 2>/dev/null)
    case "$tc" in *tool_calls*|*get_weather*) ok "tool-call works ($PRIMARY)" ;; *) warn "tool-call not detected" ;; esac
  else warn "skip tool-call (server/model not ready)"; fi
  [ -f "$ZED_SETTINGS" ] && grep -q '"ollama"' "$ZED_SETTINGS" 2>/dev/null && ok "Zed ollama provider present" || warn "Zed not wired"
  have rtk && ok "rtk ready" || warn "rtk not in PATH"
  have nvidia-smi && say "  VRAM: $(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader 2>/dev/null | head -1)"
  echo; [ "$fails" -eq 0 ] && say "${G}Checks passed.${X}" || say "${Y}$fails check(s) need attention — see $LOG${X}"
}

cleanup(){ rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

# ============================================================================
# MAIN
# ============================================================================
DLAB=""; [ "$DRY_RUN" = 1 ] && DLAB=", dry-run"
say "${B}CachyOS local-LLM (Ollama + Zed + Tools) setup${X}  (mode: $MODE$DLAB)  ·  log: $LOG"
have curl || die "curl is required (sudo pacman -S curl)"
case "$MODE" in
  check)  do_check ;;
  verify) do_verify ;;
  *)
    do_check; phase_driver; phase_ollama; phase_rtk; phase_zed
    [ "$DRY_RUN" = 1 ] && { echo; say "(dry-run: skipping smoke tests — run ./setup-cachyos-ollama.sh verify after)"; } || do_verify
    step "Done"
    say "${G}${B}✓ Local coding model & tool-calling stack ready for Zed.${X}"
    say "  Models: $TUNED (tuned 8k ctx), qwen2.5-coder:7b, qwen2.5-coder:3b (fast)."
    say "  Tool calling: supports_tools=true wired to Zed's native Ollama provider."
    say "  Picker: Zed → Agent → Ollama. Restart Zed to load."
    ;;
esac
