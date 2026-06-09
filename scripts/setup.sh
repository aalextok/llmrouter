#!/usr/bin/env bash
# llmrouter local environment setup & doctor.
#
#   ./scripts/setup.sh              detect hardware, offer to install what's missing,
#                                   recommend + pull models sized to the machine
#   ./scripts/setup.sh --check      report-only (doctor mode): changes nothing, exit 1 on gaps
#   ./scripts/setup.sh --yes        assume "yes" to every install prompt
#   ./scripts/setup.sh --no-models  skip model recommendation pulls (multi-GB downloads)
#
# Safe to re-run: every step is check-first, install-only-if-missing.
# Needs sudo for: the Go toolchain (/usr/local/go), the Ollama installer,
# and enabling the Ollama service.
set -euo pipefail

GO_MIN_MINOR=22 # accept any existing go >= 1.22; install latest stable otherwise

CHECK_ONLY=0
ASSUME_YES=0
PULL_MODELS=1
for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    --yes | -y) ASSUME_YES=1 ;;
    --no-models) PULL_MODELS=0 ;;
    -h | --help)
      sed -n '2,/^[^#]/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown flag: $arg (try --help)" >&2
      exit 2
      ;;
  esac
done

if [ "$(id -u)" = 0 ]; then
  echo "Run this as a normal user, not root — it uses sudo only where needed." >&2
  exit 2
fi

# Prompts need a terminal; anything non-interactive must opt in explicitly.
if [ "$CHECK_ONLY" = 0 ] && [ "$ASSUME_YES" = 0 ] && ! [ -t 0 ]; then
  echo "stdin is not a terminal; use --check or --yes" >&2
  exit 2
fi

if [ -t 1 ]; then
  GREEN=$'\e[32m' RED=$'\e[31m' YELLOW=$'\e[33m' BOLD=$'\e[1m' RESET=$'\e[0m'
else
  GREEN='' RED='' YELLOW='' BOLD='' RESET=''
fi

REPORT=()
MISSING=0
ok() { REPORT+=("  ${GREEN}ok${RESET}       $1"); }
warn() { REPORT+=("  ${YELLOW}warn${RESET}     $1"); }
miss() {
  REPORT+=("  ${RED}missing${RESET}  $1")
  MISSING=$((MISSING + 1))
}
say() { echo "${BOLD}==>${RESET} $*"; }

confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  local reply
  read -r -p "$1 [Y/n] " reply || return 1 # EOF means decline, never auto-yes
  case "$reply" in n | N | no | NO) return 1 ;; *) return 0 ;; esac
}

# Make install locations win over any older system copies, in this run and future shells.
persist_path() { # persist_path /usr/local/go/bin
  local dir="$1" line file
  line="export PATH=\"$dir:\$PATH\""
  for file in "$HOME/.profile" "$HOME/.bashrc"; do
    touch "$file"
    grep -qsxF "$line" "$file" || echo "$line" >>"$file"
  done
}

path_persisted() {
  local line="export PATH=\"$1:\$PATH\""
  grep -qsxF "$line" "$HOME/.profile" || grep -qsxF "$line" "$HOME/.bashrc"
}

# --- Hardware profile --------------------------------------------------
GPU_NAME=""
VRAM_MB=0
VRAM_GB=0
if command -v nvidia-smi >/dev/null && nvidia-smi >/dev/null 2>&1; then
  # One query for both fields so name and VRAM describe the same card;
  # on multi-GPU machines use the largest one. Query failures and
  # non-numeric values ([N/A], NVML errors) degrade to the CPU-only path.
  GPU_LINE=$(nvidia-smi --query-gpu=memory.total,name --format=csv,noheader,nounits 2>/dev/null |
    sort -t, -k1 -nr | head -1) || GPU_LINE=""
  VRAM_MB=${GPU_LINE%%,*}
  case "$VRAM_MB" in '' | *[!0-9]*) VRAM_MB=0 ;; esac
  if [ "$VRAM_MB" -gt 0 ]; then
    GPU_NAME=${GPU_LINE#*,}
    GPU_NAME=${GPU_NAME# }
    VRAM_GB=$(((VRAM_MB + 512) / 1024))
  fi
fi
RAM_GB=$(awk '/MemTotal/ {printf "%d", ($2 + 524288) / 1048576}' /proc/meminfo)
CPU_CORES=$(nproc)

# Models are stored wherever the Ollama service points, not necessarily under /.
ollama_models_dir() {
  local dir=""
  if command -v systemctl >/dev/null; then
    dir=$(systemctl show ollama -p Environment 2>/dev/null |
      tr ' ' '\n' | sed -n 's/^OLLAMA_MODELS=//p' | head -n1)
  fi
  [ -n "$dir" ] && { echo "$dir"; return; }
  [ -n "${OLLAMA_MODELS:-}" ] && { echo "$OLLAMA_MODELS"; return; }
  if [ -d /usr/share/ollama ]; then echo /usr/share/ollama; else echo "$HOME/.ollama"; fi
}

models_disk_avail_gb() {
  # The configured dir may not exist yet — measure the nearest existing
  # ancestor so the number describes the filesystem models will land on.
  local dir
  dir=$(ollama_models_dir)
  while [ ! -d "$dir" ] && [ "$dir" != / ]; do
    dir=$(dirname "$dir")
  done
  df -BG --output=avail "$dir" 2>/dev/null | tail -1 | tr -dc '0-9'
}

# --- Model recommendation ----------------------------------------------
# Approximate download sizes (GB, 4-bit quants) for the disk check.
declare -A MODEL_GB=(
  [llama3.2:1b]=2 [llama3.2:3b]=3
  [qwen2.5-coder:3b]=3 [qwen2.5-coder:7b]=6
  [qwen2.5-coder:14b]=10 [qwen2.5-coder:32b]=21
)

MODELS=()
MODEL_WHY=()
add_model() {
  MODELS+=("$1")
  MODEL_WHY+=("$2")
}

# Coding-first ladder: the strongest coder that fits VRAM, a small general
# model, and where RAM allows, one size above VRAM as a spill-to-RAM stress
# test (the eval needs a model that struggles locally to measure escalation).
recommend_models() {
  if [ "$VRAM_GB" -ge 20 ]; then
    add_model "qwen2.5-coder:32b" "strongest open coder that fits ${VRAM_GB} GB VRAM at 4-bit"
    add_model "qwen2.5-coder:7b" "fast-iteration coder with context headroom"
    add_model "llama3.2:3b" "small general model for routing experiments"
  elif [ "$VRAM_GB" -ge 12 ]; then
    add_model "qwen2.5-coder:14b" "fits ${VRAM_GB} GB VRAM at 4-bit — primary coder"
    add_model "qwen2.5-coder:7b" "faster coder with more context headroom"
    add_model "llama3.2:3b" "small general model for routing experiments"
    if [ "$RAM_GB" -ge 32 ]; then
      add_model "qwen2.5-coder:32b" "exceeds VRAM, spills to RAM — stress test"
    fi
  elif [ "$VRAM_GB" -ge 7 ]; then
    add_model "qwen2.5-coder:7b" "fits ${VRAM_GB} GB VRAM — full-GPU-speed primary coder"
    add_model "llama3.2:3b" "small general model for routing experiments"
    # Nominal-16GB machines report ~15 GB after kernel/firmware reservations.
    if [ "$RAM_GB" -ge 15 ]; then
      add_model "qwen2.5-coder:14b" "exceeds VRAM, spills to RAM — stress test"
    fi
  elif [ "$VRAM_GB" -ge 5 ]; then
    add_model "qwen2.5-coder:7b" "tight in ${VRAM_GB} GB VRAM — partial offload, still usable"
    add_model "llama3.2:3b" "small general model"
  elif [ "$VRAM_GB" -ge 3 ]; then
    add_model "qwen2.5-coder:3b" "fits ${VRAM_GB} GB VRAM"
    add_model "llama3.2:3b" "small general model"
  else # CPU-only
    # Same nominal-16GB allowance as the GPU branch above.
    if [ "$RAM_GB" -ge 15 ]; then
      add_model "llama3.2:3b" "CPU-friendly general model"
      add_model "qwen2.5-coder:7b" "CPU inference is slow but workable for evals"
    elif [ "$RAM_GB" -ge 8 ]; then
      add_model "llama3.2:3b" "CPU-friendly general model"
      add_model "qwen2.5-coder:3b" "small coder for ${RAM_GB} GB RAM"
    else
      add_model "llama3.2:1b" "minimal footprint for ${RAM_GB} GB RAM"
    fi
  fi
}
recommend_models

echo "${BOLD}Hardware profile${RESET}"
if [ -n "$GPU_NAME" ]; then
  echo "  GPU:   $GPU_NAME (${VRAM_GB} GB VRAM)"
else
  echo "  GPU:   none detected — CPU-only inference (on Ubuntu: sudo ubuntu-drivers install)"
fi
echo "  RAM:   ${RAM_GB} GB"
echo "  CPU:   ${CPU_CORES} cores"
echo "  Disk:  $(models_disk_avail_gb) GB free at $(ollama_models_dir)"
echo
echo "${BOLD}Recommended models for this hardware${RESET}"
for i in "${!MODELS[@]}"; do
  printf '  %-20s ~%2s GB  %s\n' "${MODELS[$i]}" "${MODEL_GB[${MODELS[$i]}]:-?}" "${MODEL_WHY[$i]}"
done
echo

# --- git ---------------------------------------------------------------
if command -v git >/dev/null; then
  ok "git $(git --version | awk '{print $3}')"
else
  miss "git — install it with the system package manager (e.g. sudo apt install git)"
fi

# --- GPU ---------------------------------------------------------------
if [ -n "$GPU_NAME" ]; then
  ok "GPU: $GPU_NAME (${VRAM_GB} GB VRAM)"
else
  warn "no working nvidia-smi — Ollama will run on CPU (slow)"
fi

# --- Go toolchain ------------------------------------------------------
go_ok() {
  command -v go >/dev/null || return 1
  local minor
  minor=$(go env GOVERSION 2>/dev/null | sed -n 's/^go1\.\([0-9]*\).*/\1/p')
  [ -n "$minor" ] && [ "$minor" -ge "$GO_MIN_MINOR" ]
}

# Download, verify, and stage the toolchain; the old /usr/local/go is
# removed only after the replacement is fully verified and unpacked.
install_go() { # install_go go1.x.y amd64|arm64
  local version="$1" arch="$2" tarball expected_sha stage
  tarball=$(mktemp /tmp/go.XXXXXX.tar.gz) || return 1
  if ! curl -fSL --progress-bar "https://go.dev/dl/${version}.linux-${arch}.tar.gz" -o "$tarball"; then
    rm -f "$tarball"
    return 1
  fi
  expected_sha=$(curl -fsSL "https://go.dev/dl/${version}.linux-${arch}.tar.gz.sha256" | awk '{print $1}') ||
    expected_sha=""
  if ! echo "${expected_sha}  ${tarball}" | sha256sum -c - >/dev/null 2>&1; then
    echo "checksum mismatch for ${version}.linux-${arch}.tar.gz" >&2
    rm -f "$tarball"
    return 1
  fi
  stage=$(mktemp -d /tmp/go-stage.XXXXXX) || { rm -f "$tarball"; return 1; }
  if ! tar -C "$stage" -xzf "$tarball"; then
    rm -rf "$stage" "$tarball"
    return 1
  fi
  rm -f "$tarball"
  if ! sudo rm -rf /usr/local/go ||
    ! sudo mv "$stage/go" /usr/local/go ||
    ! sudo chown -R root:root /usr/local/go; then
    rm -rf "$stage"
    return 1
  fi
  rm -rf "$stage"
}

# A current shell may predate the PATH change, or an older distro Go may
# shadow /usr/local/go — prepend so the right toolchain wins.
if ! go_ok && [ -x /usr/local/go/bin/go ]; then
  export PATH="/usr/local/go/bin:$PATH"
  hash -r
  if [ "$CHECK_ONLY" = 0 ]; then
    persist_path /usr/local/go/bin
  fi
fi

if go_ok; then
  ok "Go $(go env GOVERSION) ($(command -v go))"
  if [ "$CHECK_ONLY" = 1 ] && [ "$(command -v go)" = /usr/local/go/bin/go ] &&
    ! path_persisted /usr/local/go/bin; then
    miss "Go PATH entry in ~/.profile or ~/.bashrc (new shells will not find go)"
  fi
elif [ "$CHECK_ONLY" = 1 ]; then
  miss "Go >= 1.$GO_MIN_MINOR"
else
  GOARCH=""
  case "$(uname -m)" in
    x86_64) GOARCH=amd64 ;;
    aarch64 | arm64) GOARCH=arm64 ;;
  esac
  GO_VERSION=$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n1) || GO_VERSION=""
  if [ -z "$GOARCH" ]; then
    miss "Go — unsupported architecture: $(uname -m)"
  elif ! [[ $GO_VERSION =~ ^go1\.[0-9]+(\.[0-9]+)?$ ]]; then
    miss "Go — could not get a valid latest version from go.dev (got: ${GO_VERSION:-nothing})"
  elif confirm "Install $GO_VERSION to /usr/local/go (needs sudo)?"; then
    say "downloading $GO_VERSION linux/$GOARCH"
    if install_go "$GO_VERSION" "$GOARCH"; then
      export PATH="/usr/local/go/bin:$PATH"
      hash -r
      persist_path /usr/local/go/bin
      if go_ok; then
        ok "Go $(go env GOVERSION) (freshly installed)"
      else
        miss "Go — installed to /usr/local/go but $(command -v go || echo nothing) resolves first"
      fi
    else
      miss "Go — download, verification, or install failed (re-run to retry)"
    fi
  else
    miss "Go >= 1.$GO_MIN_MINOR (declined)"
  fi
fi

# --- staticcheck (standing lint loop alongside gofmt / go vet) ----------
if go_ok; then
  GOBIN_DIR=$(go env GOBIN)
  [ -z "$GOBIN_DIR" ] && GOBIN_DIR="$(go env GOPATH)/bin"
  if [ -x "$GOBIN_DIR/staticcheck" ] || command -v staticcheck >/dev/null; then
    ok "staticcheck"
  elif [ "$CHECK_ONLY" = 1 ]; then
    miss "staticcheck (go install honnef.co/go/tools/cmd/staticcheck@latest)"
  elif confirm "Install staticcheck into $GOBIN_DIR?"; then
    say "go install honnef.co/go/tools/cmd/staticcheck@latest"
    if go install honnef.co/go/tools/cmd/staticcheck@latest; then
      persist_path "$GOBIN_DIR"
      ok "staticcheck (freshly installed)"
    else
      miss "staticcheck — go install failed (network/proxy; re-run to retry)"
    fi
  else
    miss "staticcheck (declined)"
  fi
else
  miss "staticcheck (needs Go first)"
fi

# --- Ollama ------------------------------------------------------------
ollama_version() {
  ollama --version 2>/dev/null | sed -n 's/^ollama version is //p' | head -n1
}

if command -v ollama >/dev/null; then
  ok "ollama $(ollama_version)"
elif [ "$CHECK_ONLY" = 1 ]; then
  miss "ollama"
elif confirm "Install Ollama via the official installer (needs sudo)?"; then
  say "running the ollama.com installer"
  INSTALL_SH=$(mktemp /tmp/ollama-install.XXXXXX.sh) || INSTALL_SH=""
  if [ -n "$INSTALL_SH" ] &&
    curl -fsSL https://ollama.com/install.sh -o "$INSTALL_SH" &&
    sh "$INSTALL_SH"; then
    ok "ollama $(ollama_version) (freshly installed)"
  else
    miss "ollama — installer failed (re-run to retry)"
  fi
  rm -f "$INSTALL_SH"
else
  miss "ollama (declined)"
fi

# --- Ollama service ----------------------------------------------------
ollama_up() { curl -fsS --max-time 2 http://127.0.0.1:11434/api/version >/dev/null 2>&1; }

if command -v ollama >/dev/null; then
  if ollama_up; then
    ok "ollama server responding on :11434"
  elif [ "$CHECK_ONLY" = 1 ]; then
    miss "ollama server not responding on :11434"
  else
    if command -v systemctl >/dev/null && systemctl cat ollama.service >/dev/null 2>&1; then
      say "starting ollama.service"
      if ! sudo systemctl enable --now ollama; then
        warn "could not start ollama.service (see: systemctl status ollama)"
      fi
      sleep 2
    fi
    if ollama_up; then
      ok "ollama server responding on :11434"
    else
      miss "ollama server — nothing on :11434; start it with 'ollama serve' or fix the service"
    fi
  fi
fi

# --- Models ------------------------------------------------------------
if command -v ollama >/dev/null && ollama_up; then
  if [ "$PULL_MODELS" = 1 ]; then
    INSTALLED=$(ollama list 2>/dev/null | tail -n +2 | awk '{print $1}') || INSTALLED=""
    for model in "${MODELS[@]}"; do
      if echo "$INSTALLED" | grep -qxF "$model"; then
        ok "model $model"
      elif [ "$CHECK_ONLY" = 1 ]; then
        miss "model $model"
      else
        NEED_GB=$((${MODEL_GB[$model]:-6} + 2)) # download + headroom
        AVAIL_GB=$(models_disk_avail_gb) || AVAIL_GB=""
        if [ "${AVAIL_GB:-0}" -lt "$NEED_GB" ]; then
          miss "model $model — only ${AVAIL_GB} GB free at $(ollama_models_dir), needs ~${NEED_GB} GB"
          continue
        fi
        if confirm "Pull $model (~${MODEL_GB[$model]:-?} GB download)?"; then
          if ollama pull "$model"; then
            ok "model $model (freshly pulled)"
          else
            miss "model $model — pull failed (retry: ollama pull $model)"
          fi
        else
          miss "model $model (declined)"
        fi
      fi
    done
  else
    warn "model pulls skipped (--no-models)"
  fi
fi

# --- Summary -----------------------------------------------------------
echo
echo "${BOLD}llmrouter environment report${RESET}"
for line in "${REPORT[@]}"; do echo "$line"; done
echo
if [ "$MISSING" -gt 0 ]; then
  echo "${RED}$MISSING item(s) missing.${RESET} Re-run ./scripts/setup.sh to fix, or see README → Local environment."
  exit 1
fi
echo "${GREEN}Environment ready.${RESET} Open a new shell (or 'source ~/.profile') if anything was just installed."
