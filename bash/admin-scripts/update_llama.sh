#!/usr/bin/env bash
# update_llama.sh – Update & rebuild llama.cpp with CUDA support (Rocky Linux 10)
# Usage: ./update_llama.sh [--no-cuda] [--force] [--jobs N] [--branch BRANCH] [--help]
set -euo pipefail

# ─── Constants ────────────────────────────────────────────────────────────────
readonly LLAMA_DIR="${LLAMA_DIR:-$HOME/llama.cpp}"
readonly REPO_URL="https://github.com/ggml-org/llama.cpp.git"
readonly LOG_FILE="$HOME/llama_update_$(date +%Y%m%d_%H%M%S).log"
readonly LOCK_FILE="/tmp/llama_update.lock"
readonly MIN_DISK_MB=2048

readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'

# ─── Defaults (overridable via flags) ─────────────────────────────────────────
ENABLE_CUDA=true
FORCE_BUILD=false
JOBS="$(nproc 2>/dev/null || echo 4)"
TARGET_BRANCH=""

# ─── Helpers ──────────────────────────────────────────────────────────────────
log()  { printf '%s\n' "$1" >> "$LOG_FILE"; }
info() { printf "${GREEN}[INFO]${NC} %s\n" "$1"; log "[INFO] $1"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; log "[WARN] $1"; }
err()  { printf "${RED}[ERROR]${NC} %s\n" "$1" >&2; log "[ERROR] $1"; }

die() { err "$1"; cleanup; exit 1; }

cleanup() {
    # Restore stash if build failed mid-way
    if [[ "${STASHED:-false}" == true ]] && [[ -d "$LLAMA_DIR/.git" ]]; then
        warn "Restoring stashed changes after failure..."
        git -C "$LLAMA_DIR" stash pop >> "$LOG_FILE" 2>&1 || true
    fi
    rm -f "$LOCK_FILE"
}
trap cleanup EXIT

has_cmd() { command -v "$1" &>/dev/null; }

# ─── Argument Parsing ─────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --no-cuda       Build without CUDA support
  --force         Rebuild even if already up to date
  --jobs N        Parallel build jobs (default: nproc)
  --branch NAME   Track a specific branch instead of latest tag
  --help          Show this help
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-cuda)  ENABLE_CUDA=false ;;
        --force)    FORCE_BUILD=true ;;
        --jobs)     JOBS="$2"; shift ;;
        --branch)   TARGET_BRANCH="$2"; shift ;;
        --help|-h)  usage ;;
        *)          die "Unknown option: $1 (use --help)" ;;
    esac
    shift
done

# ─── Lock ─────────────────────────────────────────────────────────────────────
if [[ -e "$LOCK_FILE" ]]; then
    die "Another instance is running (lock: $LOCK_FILE). Remove it if stale."
fi
echo $$ > "$LOCK_FILE"

echo "=== llama.cpp Update Started at $(date) ===" > "$LOG_FILE"
info "Log: $LOG_FILE"

# ─── Prerequisites ────────────────────────────────────────────────────────────
info "Checking prerequisites..."

for cmd in git cmake make; do
    has_cmd "$cmd" || die "'$cmd' not found. Install: sudo dnf install $cmd"
done

if [[ ! -d "$LLAMA_DIR/.git" ]]; then
    info "Cloning llama.cpp..."
    git clone "$REPO_URL" "$LLAMA_DIR" >> "$LOG_FILE" 2>&1
fi

# Disk space
avail_mb=$(df -m "$LLAMA_DIR" | awk 'NR==2{print $4}')
(( avail_mb >= MIN_DISK_MB )) || die "Insufficient disk space (${avail_mb}MB < ${MIN_DISK_MB}MB)"

# ─── CUDA Detection ──────────────────────────────────────────────────────────
if [[ "$ENABLE_CUDA" == true ]]; then
    if has_cmd nvidia-smi; then
        info "GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
        info "Driver: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)"
    else
        warn "nvidia-smi not found; disabling CUDA."
        ENABLE_CUDA=false
    fi
    if ! has_cmd nvcc; then
        warn "nvcc not in PATH; disabling CUDA."
        warn "Install: https://developer.nvidia.com/cuda-downloads"
        ENABLE_CUDA=false
    fi
fi

# ─── Git Update ───────────────────────────────────────────────────────────────
pushd "$LLAMA_DIR" >> "$LOG_FILE"

CURRENT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
info "Current commit: $CURRENT_COMMIT"

# Stash local changes
STASHED=false
if ! git diff --quiet || ! git diff --cached --quiet; then
    warn "Stashing local changes..."
    git stash push -m "auto-stash $(date -Iseconds)" >> "$LOG_FILE" 2>&1
    STASHED=true
fi

info "Fetching..."
git fetch --all --prune >> "$LOG_FILE" 2>&1 || die "git fetch failed"

if [[ -n "$TARGET_BRANCH" ]]; then
    git checkout "$TARGET_BRANCH" >> "$LOG_FILE" 2>&1
    git pull --ff-only origin "$TARGET_BRANCH" >> "$LOG_FILE" 2>&1
else
    LATEST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
    if [[ -n "$LATEST_TAG" ]]; then
        info "Checking out tag: $LATEST_TAG"
        git checkout "$LATEST_TAG" >> "$LOG_FILE" 2>&1
    else
        git checkout main >> "$LOG_FILE" 2>&1
        git pull --ff-only origin main >> "$LOG_FILE" 2>&1
    fi
fi

NEW_COMMIT=$(git rev-parse --short HEAD)
info "New commit: $NEW_COMMIT"

if [[ "$CURRENT_COMMIT" == "$NEW_COMMIT" && "$FORCE_BUILD" == false ]]; then
    info "Already up to date."
    [[ "$STASHED" == true ]] && git stash pop >> "$LOG_FILE" 2>&1
    popd >> "$LOG_FILE"
    exit 0
fi

# ─── Build ────────────────────────────────────────────────────────────────────
info "Cleaning previous build..."
rm -rf build
mkdir -p build && cd build

CMAKE_ARGS=(-DCMAKE_BUILD_TYPE=Release)

# Enable ccache if available to speed up rebuilds
if has_cmd ccache; then
    info "ccache detected; enabling compiler caching."
    CMAKE_ARGS+=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
fi

if [[ "$ENABLE_CUDA" == true ]]; then
    CMAKE_ARGS+=(-DGGML_CUDA=ON)
    info "Configuring with CUDA..."
else
    info "Configuring CPU-only build..."
fi

if ! cmake .. "${CMAKE_ARGS[@]}" >> "$LOG_FILE" 2>&1; then
    if [[ "$ENABLE_CUDA" == true ]]; then
        warn "CUDA cmake failed; retrying CPU-only..."
        rm -rf ./*
        cmake .. -DCMAKE_BUILD_TYPE=Release >> "$LOG_FILE" 2>&1 \
            || die "cmake failed (see $LOG_FILE)"
    else
        die "cmake failed (see $LOG_FILE)"
    fi
fi

info "Building with $JOBS jobs..."
make -j"$JOBS" >> "$LOG_FILE" 2>&1 || die "Build failed (see $LOG_FILE)"

# ─── Verify ───────────────────────────────────────────────────────────────────
[[ -x bin/llama-cli ]] || die "Binary bin/llama-cli not found after build"
info "Version: $(./bin/llama-cli --version 2>/dev/null | head -1 || echo unknown)"

# ─── Restore Stash ────────────────────────────────────────────────────────────
cd "$LLAMA_DIR"
if [[ "$STASHED" == true ]]; then
    git stash pop >> "$LOG_FILE" 2>&1 \
        || warn "Stash pop failed. Recover with: git -C $LLAMA_DIR stash list"
    STASHED=false  # prevent cleanup trap from double-popping
fi
popd >> "$LOG_FILE"

# ─── Summary ──────────────────────────────────────────────────────────────────
cat <<EOF

${GREEN}✓ Update complete${NC}
  Old commit : $CURRENT_COMMIT
  New commit : $NEW_COMMIT
  CUDA       : $ENABLE_CUDA
  Binaries   : $LLAMA_DIR/build/bin/
  Log        : $LOG_FILE

Run: $LLAMA_DIR/build/bin/llama-cli --help
EOF