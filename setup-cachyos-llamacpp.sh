#!/usr/bin/env bash
# ============================================================================
# Local coding LLM on CachyOS / Arch + NVIDIA (e.g. RTX 3060 laptop, 6GB VRAM),
# served by llama.cpp (CUDA) and wired into the Zed editor's Agent panel.
# NO Claude Code — just a local OpenAI-compatible coding model for Zed.
#
#   ./setup-cachyos-llamacpp.sh           # check → install → serve → wire Zed → verify
#   ./setup-cachyos-llamacpp.sh check     # read-only inventory
#   ./setup-cachyos-llamacpp.sh verify    # smoke tests only
#   ./setup-cachyos-llamacpp.sh --3b      # use the smaller 3B model (comfortable in 6GB)
#   ./setup-cachyos-llamacpp.sh --dry-run # print actions, change nothing
#
# WRITTEN FOR Arch/CachyOS + NVIDIA; syntax-checked but UNTESTED on that hardware.
# Run `check` first; sudo/AUR/pacman prompts are shown (not hidden).
# ============================================================================
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -uo pipefail

# ---- tunables (6GB VRAM defaults) ------------------------------------------
MODELS_DIR="$HOME/.local/share/llama-models"
PORT=8080
HOSTADDR="127.0.0.1"
NGL=99            # GPU layers to offload (99 = all). Lower if you hit CUDA OOM.
CTX=8192          # context window. Lower (4096) if OOM.
ALIAS="qwen2.5-coder"
# 7B Q4_K_M (~4.7GB) = best coder that fits 6GB with -fa; 3B (~2GB) = comfortable fallback.
REPO_7B="bartowski/Qwen2.5-Coder-7B-Instruct-GGUF"; FILE_7B="Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf"
REPO_3B="bartowski/Qwen2.5-Coder-3B-Instruct-GGUF"; FILE_3B="Qwen2.5-Coder-3B-Instruct-Q4_K_M.gguf"
REPO="$REPO_7B"; FILE="$FILE_7B"; WHICH=7B
ZED_SETTINGS="$HOME/.config/zed/settings.json"
LOG="${TMPDIR:-/tmp}/cachyos-llamacpp-setup.log"
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
server_up(){ curl -sf "http://$HOSTADDR:$PORT/health" >/dev/null 2>&1 || curl -sf "http://$HOSTADDR:$PORT/v1/models" >/dev/null 2>&1; }

for a in "$@"; do case "$a" in
  check) MODE=check ;; verify) MODE=verify ;; --dry-run) DRY_RUN=1 ;;
  --3b) REPO="$REPO_3B"; FILE="$FILE_3B"; WHICH=3B; CTX=8192 ;;
  -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
esac; done
GGUF="$MODELS_DIR/$FILE"

# ---- CHECK ------------------------------------------------------------------
do_check(){
  step "Check — CachyOS/Arch + NVIDIA + llama.cpp + Zed"
  have pacman && ok "Arch-based ($(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Arch}"))" || { miss "not Arch-based (this script targets pacman)"; }
  if have nvidia-smi; then
    local vram; vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
    ok "NVIDIA GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1) — ${vram} MiB VRAM"
    [ "${vram:-0}" -lt 6500 ] 2>/dev/null && warn "≤6GB VRAM: use the 7B Q4 with -fa (default) or --3b if you hit CUDA OOM"
  else miss "no nvidia-smi — install the NVIDIA driver first (pacman -S nvidia-utils)"; fi
  have nvcc && ok "CUDA toolkit (nvcc $(nvcc --version 2>/dev/null | grep -oE 'release [0-9.]+' | head -1))" || warn "no nvcc (only needed if building llama.cpp from source)"
  have llama-server && ok "llama.cpp (llama-server present)" || miss "llama.cpp / llama-server"
  [ -f "$GGUF" ] && ok "model present: $FILE ($(du -h "$GGUF" 2>/dev/null | cut -f1))" || miss "model $FILE (will download to $MODELS_DIR)"
  server_up && ok "llama-server responding on :$PORT" || warn "llama-server not running on :$PORT"
  { have zed || [ -d "$HOME/.config/zed" ]; } && ok "Zed present" || miss "Zed (install: https://zed.dev/download or pacman/AUR)"
  if [ -f "$ZED_SETTINGS" ] && grep -q "$HOSTADDR:$PORT" "$ZED_SETTINGS" 2>/dev/null; then ok "Zed already points at the local server"; else warn "Zed not yet wired to the local server"; fi
}

# ---- install llama.cpp (package → AUR → source build with CUDA) -------------
phase_llamacpp(){
  step "llama.cpp (CUDA)"
  if have llama-server; then ok "llama-server already installed"; return 0; fi
  [ "$DRY_RUN" = 1 ] && { act "install llama.cpp-cuda (pacman/AUR) or build with -DGGML_CUDA=ON"; return 0; }
  if pacman -Si llama.cpp-cuda >/dev/null 2>&1; then act "pacman llama.cpp-cuda"; sudo pacman -S --needed --noconfirm llama.cpp-cuda
  elif have yay;  then act "AUR (yay) llama.cpp-cuda";  yay  -S --needed --noconfirm llama.cpp-cuda
  elif have paru; then act "AUR (paru) llama.cpp-cuda"; paru -S --needed --noconfirm llama.cpp-cuda
  else
    warn "no llama.cpp package/AUR helper — building from source with CUDA"
    sudo pacman -S --needed --noconfirm base-devel cmake git cuda || warn "couldn't install build deps"
    local src="$HOME/.local/src/llama.cpp"
    [ -d "$src" ] || git clone --depth 1 https://github.com/ggml-org/llama.cpp "$src"
    cmake -S "$src" -B "$src/build" -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release >>"$LOG" 2>&1
    cmake --build "$src/build" --config Release -j --target llama-server llama-cli >>"$LOG" 2>&1
    sudo install -m755 "$src/build/bin/llama-server" /usr/local/bin/llama-server 2>/dev/null || { mkdir -p "$HOME/.local/bin"; install -m755 "$src/build/bin/llama-server" "$HOME/.local/bin/llama-server"; warn "installed to ~/.local/bin (ensure it's on PATH)"; }
  fi
  hash -r 2>/dev/null || true
  have llama-server && ok "llama-server installed" || warn "llama-server still not found — see $LOG"
}

# ---- download model ---------------------------------------------------------
phase_model(){
  step "Model — $FILE ($WHICH)"
  mkdir -p "$MODELS_DIR"
  if [ -f "$GGUF" ]; then ok "already downloaded ($(du -h "$GGUF" | cut -f1))"; return 0; fi
  act "downloading from huggingface.co/$REPO (resumable)"
  [ "$DRY_RUN" = 1 ] && return 0
  curl -fL -C - -o "$GGUF" "https://huggingface.co/$REPO/resolve/main/$FILE" || { warn "download failed — check the repo/file name on huggingface.co/$REPO"; return 1; }
  ok "downloaded ($(du -h "$GGUF" | cut -f1))"
}

# ---- serve via systemd --user (persists, restarts) --------------------------
phase_serve(){
  step "Serve llama.cpp (systemd --user, port $PORT)"
  local llbin; llbin="$(command -v llama-server || echo /usr/bin/llama-server)"
  local unit="$HOME/.config/systemd/user/llama-server.service"
  if [ "$DRY_RUN" = 1 ]; then act "write $unit + systemctl --user enable --now llama-server"; return 0; fi
  mkdir -p "$(dirname "$unit")"
  cat > "$unit" <<EOF
[Unit]
Description=llama.cpp server (Qwen2.5-Coder, local Zed coding model)
After=network-online.target

[Service]
ExecStart=$llbin -m "$GGUF" --alias $ALIAS -ngl $NGL -c $CTX -fa --jinja --host $HOSTADDR --port $PORT
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload 2>/dev/null
  systemctl --user enable --now llama-server.service 2>/dev/null || { warn "systemd --user unavailable — starting in background instead"; nohup "$llbin" -m "$GGUF" --alias "$ALIAS" -ngl "$NGL" -c "$CTX" -fa --jinja --host "$HOSTADDR" --port "$PORT" >/tmp/llama-server.log 2>&1 & }
  for _ in $(seq 1 40); do server_up && break; sleep 1; done
  server_up && ok "llama-server up on http://$HOSTADDR:$PORT (model alias: $ALIAS)" || warn "server didn't come up — check 'journalctl --user -u llama-server' or /tmp/llama-server.log (CUDA OOM? try --3b or lower NGL/CTX)"
}

# ---- wire Zed (OpenAI-compatible provider → llama.cpp) ----------------------
phase_zed(){
  step "Wire Zed → local llama.cpp"
  if ! { have zed || [ -d "$HOME/.config/zed" ]; }; then warn "Zed not found — skipping. Install Zed, then re-run, or add the snippet below by hand."; print_zed_snippet; return 0; fi
  if [ "$DRY_RUN" = 1 ]; then act "merge openai_compatible provider into $ZED_SETTINGS"; print_zed_snippet; return 0; fi
  if ! have node; then warn "node not found — can't auto-merge Zed settings. Add this by hand:"; print_zed_snippet; return 0; fi
  ZED_FILE="$ZED_SETTINGS" PORT="$PORT" HOSTADDR="$HOSTADDR" ALIAS="$ALIAS" CTX="$CTX" WHICH="$WHICH" node - <<'N_ZED' || { warn "auto-merge failed — add this by hand:"; print_zed_snippet; }
import { readFileSync, writeFileSync, existsSync, mkdirSync, copyFileSync } from "node:fs";
import { dirname } from "node:path";
const f = process.env.ZED_FILE;
const prov = {
  api_url: `http://${process.env.HOSTADDR}:${process.env.PORT}/v1`,
  available_models: [{ name: process.env.ALIAS, display_name: `Qwen2.5-Coder ${process.env.WHICH} (local llama.cpp)`, max_tokens: Number(process.env.CTX), supports_tools: true }],
};
let s = {};
if (existsSync(f)) { copyFileSync(f, f + ".bak." + Date.now());
  const noComments = readFileSync(f,"utf8").split("\n").filter(l=>!l.trimStart().startsWith("//")).join("\n").replace(/,(\s*[}\]])/g,"$1");
  try { s = JSON.parse(noComments); } catch { console.error("ZED_PARSE_FAIL"); process.exit(3); } }
s.language_models = s.language_models || {};
s.language_models.openai_compatible = s.language_models.openai_compatible || {};
s.language_models.openai_compatible.llamacpp = prov;
mkdirSync(dirname(f), { recursive: true });
writeFileSync(f, JSON.stringify(s, null, 2) + "\n");
console.log("zed wired");
N_ZED
  grep -q "$HOSTADDR:$PORT" "$ZED_SETTINGS" 2>/dev/null && ok "Zed wired to the local model (provider: llamacpp → $ALIAS)" || true
  say "  In Zed: Agent panel → model picker → ${B}llamacpp / Qwen2.5-Coder${X}. (Restart Zed to load.)"
}

print_zed_snippet(){
  say "  Add to ~/.config/zed/settings.json:"
  cat <<EOF
  "language_models": {
    "openai_compatible": {
      "llamacpp": {
        "api_url": "http://$HOSTADDR:$PORT/v1",
        "available_models": [
          { "name": "$ALIAS", "display_name": "Qwen2.5-Coder $WHICH (local llama.cpp)", "max_tokens": $CTX, "supports_tools": true }
        ]
      }
    }
  }
EOF
}

# ---- verify -----------------------------------------------------------------
do_verify(){
  step "Verify"
  local fails=0
  have llama-server && ok "llama-server installed" || { miss "llama-server missing"; fails=$((fails+1)); }
  if server_up; then
    ok "server responds on :$PORT"
    local comp; comp=$(curl -s "http://$HOSTADDR:$PORT/v1/chat/completions" -H "content-type: application/json" \
      -d "{\"model\":\"$ALIAS\",\"max_tokens\":24,\"messages\":[{\"role\":\"user\",\"content\":\"reply with the single word: ok\"}]}" 2>/dev/null)
    case "$comp" in *'"content"'*) ok "chat completion works" ;; *) warn "completion test inconclusive"; fails=$((fails+1)) ;; esac
    local tc; tc=$(curl -s "http://$HOSTADDR:$PORT/v1/chat/completions" -H "content-type: application/json" \
      -d "{\"model\":\"$ALIAS\",\"messages\":[{\"role\":\"user\",\"content\":\"weather in Draper, UT? use the tool\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"get_weather\",\"description\":\"w\",\"parameters\":{\"type\":\"object\",\"properties\":{\"location\":{\"type\":\"string\"}},\"required\":[\"location\"]}}}]}" 2>/dev/null)
    case "$tc" in *tool_calls*|*get_weather*) ok "tool-calling works (--jinja)" ;; *) warn "tool-calling not detected (Zed agentic edits may be limited)" ;; esac
  else warn "server not up — can't run completion tests"; fails=$((fails+1)); fi
  have nvidia-smi && say "  VRAM in use: $(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader 2>/dev/null | head -1)"
  echo; [ "$fails" -eq 0 ] && say "${G}All checks passed.${X}" || say "${Y}$fails check(s) need attention — see $LOG${X}"
}

# ============================================================================
# MAIN
# ============================================================================
DLAB=""; [ "$DRY_RUN" = 1 ] && DLAB=", dry-run"
say "${B}CachyOS local-LLM (llama.cpp + Zed) setup${X}  (mode: $MODE, model: $WHICH$DLAB)  ·  log: $LOG"
have curl || die "curl is required (sudo pacman -S curl)"
case "$MODE" in
  check)  do_check ;;
  verify) do_verify ;;
  *)
    do_check
    have nvidia-smi || warn "No NVIDIA GPU detected — llama.cpp will fall back to CPU (slow). Install the driver (pacman -S nvidia-utils) for GPU."
    phase_llamacpp
    phase_model
    phase_serve
    phase_zed
    [ "$DRY_RUN" = 1 ] && { echo; say "(dry-run: skipping smoke tests — run ./setup-cachyos-llamacpp.sh verify after)"; } || do_verify
    step "Done"
    say "${G}${B}✓ Local coding model is serving for Zed.${X}"
    say "  Model: Qwen2.5-Coder $WHICH (Q4_K_M) · endpoint: http://$HOSTADDR:$PORT/v1 · alias: $ALIAS"
    say "  Restart Zed → Agent panel → pick 'llamacpp / Qwen2.5-Coder'. Manage: systemctl --user {status,restart} llama-server"
    say "  If CUDA OOM: re-run with --3b, or lower NGL ($NGL) / CTX ($CTX) at the top of this script."
    ;;
esac
