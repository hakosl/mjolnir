#!/usr/bin/env bash
# Mjolnir Install Script
# Sets up all dependencies for running Mjolnir on VPS, Raspberry Pi, or macOS.
# Usage: bash install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "================================================"
echo "  Mjolnir — Install Script"
echo "================================================"
echo ""

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------
detect_platform() {
    local os="$(uname -s)"
    local arch="$(uname -m)"

    if [[ "$os" == "Darwin" ]]; then
        echo "macos"
    elif [[ "$os" == "Linux" && "$arch" == "aarch64" ]]; then
        echo "rpi"
    elif [[ "$os" == "Linux" ]]; then
        echo "linux"
    else
        echo "unknown"
    fi
}

PLATFORM="$(detect_platform)"
echo "Detected platform: ${PLATFORM}"
echo ""

# ---------------------------------------------------------------------------
# Check/install system dependencies
# ---------------------------------------------------------------------------
check_cmd() {
    command -v "$1" &>/dev/null
}

install_system_deps() {
    echo "--- Installing system dependencies ---"

    if [[ "$PLATFORM" == "macos" ]]; then
        if ! check_cmd brew; then
            echo "Error: Homebrew not found. Install from https://brew.sh"
            exit 1
        fi
        brew install tmux jq python3 curl git 2>/dev/null || true

    elif [[ "$PLATFORM" == "linux" || "$PLATFORM" == "rpi" ]]; then
        if check_cmd apt-get; then
            sudo apt-get update -qq
            sudo apt-get install -y -qq tmux jq python3 python3-pip python3-venv curl git
        elif check_cmd dnf; then
            sudo dnf install -y tmux jq python3 python3-pip curl git
        elif check_cmd pacman; then
            sudo pacman -S --noconfirm tmux jq python python-pip curl git
        else
            echo "Error: No supported package manager found (apt, dnf, pacman)"
            exit 1
        fi
    fi

    echo "System dependencies OK"
    echo ""
}

# ---------------------------------------------------------------------------
# Node.js (v18+)
# ---------------------------------------------------------------------------
install_nodejs() {
    echo "--- Checking Node.js ---"

    if check_cmd node; then
        local node_version
        node_version="$(node -v | sed 's/v//' | cut -d. -f1)"
        if [[ "$node_version" -ge 18 ]]; then
            echo "Node.js $(node -v) OK"
            return
        else
            echo "Node.js $(node -v) is too old (need v18+)"
        fi
    fi

    echo "Installing Node.js v18+..."

    if [[ "$PLATFORM" == "macos" ]]; then
        brew install node@18 2>/dev/null || brew install node

    elif [[ "$PLATFORM" == "linux" || "$PLATFORM" == "rpi" ]]; then
        if check_cmd apt-get; then
            # NodeSource setup
            curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
            sudo apt-get install -y -qq nodejs
        elif check_cmd dnf; then
            curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo bash -
            sudo dnf install -y nodejs
        fi
    fi

    echo "Node.js $(node -v) installed"
    echo ""
}

# ---------------------------------------------------------------------------
# Claude Code CLI
# ---------------------------------------------------------------------------
install_claude_code() {
    echo "--- Checking Claude Code CLI ---"

    if check_cmd claude; then
        echo "Claude Code CLI found: $(claude --version 2>/dev/null || echo 'installed')"
    else
        echo "Installing Claude Code CLI..."
        npm install -g @anthropic-ai/claude-code
        echo "Claude Code CLI installed"
    fi

    echo ""
    echo "IMPORTANT: You must authenticate Claude Code."
    echo "Run one of:"
    echo "  claude login          # Interactive browser login"
    echo "  claude setup-token    # Paste API key or session token"
    echo ""
}

# ---------------------------------------------------------------------------
# Playwright + Chromium
# ---------------------------------------------------------------------------
install_playwright() {
    echo "--- Installing Playwright + Chromium ---"

    if [[ "$PLATFORM" == "rpi" ]]; then
        echo "Raspberry Pi detected: using system Chromium"
        if check_cmd apt-get; then
            sudo apt-get install -y -qq chromium-browser || sudo apt-get install -y -qq chromium
        fi
        # Tell Playwright to use system chromium
        export PLAYWRIGHT_BROWSERS_PATH=0

        # Install playwright package (needed for CLI)
        npx playwright install-deps 2>/dev/null || true
        echo "Playwright CLI available via npx. System Chromium will be used."
    else
        # Standard install: download bundled Chromium
        npx playwright install --with-deps chromium
        echo "Playwright + Chromium installed"
    fi

    echo ""
}

# ---------------------------------------------------------------------------
# Python dependencies
# ---------------------------------------------------------------------------
install_python_deps() {
    echo "--- Installing Python dependencies ---"

    # tomli is needed for Python < 3.11 (tomllib is built-in from 3.11+)
    local python_minor
    python_minor="$(python3 -c 'import sys; print(sys.version_info.minor)')"

    if [[ "$python_minor" -lt 11 ]]; then
        pip3 install --user tomli 2>/dev/null || pip3 install tomli
        echo "Installed tomli (Python < 3.11)"
    else
        echo "Python 3.11+ detected: tomllib built-in"
    fi

    echo "Python dependencies OK"
    echo ""
}

# ---------------------------------------------------------------------------
# Make scripts executable
# ---------------------------------------------------------------------------
setup_scripts() {
    echo "--- Setting up Mjolnir scripts ---"
    chmod +x "${SCRIPT_DIR}/mjolnir.sh"
    chmod +x "${SCRIPT_DIR}/mjolnir-watchdog.sh"
    chmod +x "${SCRIPT_DIR}/install.sh"
    echo "Scripts made executable"
    echo ""
}

# ---------------------------------------------------------------------------
# Create workspace directory
# ---------------------------------------------------------------------------
setup_workspace() {
    echo "--- Setting up workspace ---"
    mkdir -p "${SCRIPT_DIR}/workspace"
    echo "Workspace directory created at ${SCRIPT_DIR}/workspace/"
    echo ""
}

# ---------------------------------------------------------------------------
# Cron watchdog
# ---------------------------------------------------------------------------
setup_watchdog_cron() {
    echo "--- Watchdog cron setup ---"
    echo ""
    echo "To enable automatic crash recovery, add this to your crontab:"
    echo "  crontab -e"
    echo ""
    echo "Then add (replace <project-dir> with your actual project path):"
    echo "  */5 * * * * ${SCRIPT_DIR}/mjolnir-watchdog.sh <project-dir>"
    echo ""
    echo "Skipping automatic crontab modification for safety."
    echo ""
}

# ---------------------------------------------------------------------------
# ntfy.sh setup
# ---------------------------------------------------------------------------
setup_notifications() {
    echo "--- Notification setup (ntfy.sh) ---"
    echo ""
    echo "Mjolnir uses ntfy.sh for push notifications."
    echo ""
    echo "1. Install the ntfy app on your phone:"
    echo "   iOS:     https://apps.apple.com/app/ntfy/id1625396347"
    echo "   Android: https://play.google.com/store/apps/details?id=io.heckel.ntfy"
    echo ""
    echo "2. Subscribe to topic: mjolnir-harness"
    echo "   (or set MJOLNIR_NTFY_TOPIC to a custom topic)"
    echo ""
    echo "3. Test notification:"
    echo "   python3 ${SCRIPT_DIR}/lib/notify.py 'Mjolnir test notification' 'info'"
    echo ""
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
verify_install() {
    echo "================================================"
    echo "  Verification"
    echo "================================================"
    echo ""

    local all_ok=true

    for cmd in tmux jq python3 node npm claude; do
        if check_cmd "$cmd"; then
            local version
            version="$($cmd --version 2>/dev/null | head -1 || echo 'OK')"
            printf "  %-12s %s\n" "$cmd" "$version"
        else
            printf "  %-12s MISSING\n" "$cmd"
            all_ok=false
        fi
    done

    # Check Playwright
    if npx playwright --version &>/dev/null; then
        printf "  %-12s %s\n" "playwright" "$(npx playwright --version 2>/dev/null)"
    else
        printf "  %-12s MISSING\n" "playwright"
        all_ok=false
    fi

    echo ""

    if [[ "$all_ok" == "true" ]]; then
        echo "All dependencies verified!"
    else
        echo "Some dependencies are missing. Please install them manually."
    fi

    echo ""
    echo "================================================"
    echo "  Quick Start"
    echo "================================================"
    echo ""
    echo "1. Copy the project template:"
    echo "   mkdir -p workspace/my-project"
    echo "   cp templates/project.toml.example workspace/my-project/project.toml"
    echo ""
    echo "2. Edit the project config:"
    echo "   \$EDITOR workspace/my-project/project.toml"
    echo ""
    echo "3. Run Mjolnir (in tmux for persistence):"
    echo "   tmux new-session -s mjolnir './mjolnir.sh workspace/my-project'"
    echo ""
    echo "4. Detach with Ctrl+B, D. Reattach with:"
    echo "   tmux attach -t mjolnir"
    echo ""
    echo "5. Monitor from another machine:"
    echo "   ssh your-server 'tail -f workspace/my-project/mjolnir.log | python3 -m json.tool'"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
install_system_deps
install_nodejs
install_claude_code
install_playwright
install_python_deps
setup_scripts
setup_workspace
setup_watchdog_cron
setup_notifications
verify_install
