#!/usr/bin/env bash
# ============================================================
#  Fresh Ubuntu Server Setup
#  Installs: fish, fail2ban, docker, docker compose, claude code
#  Configures: SSH key-only auth, UFW firewall, new sudo user
#
#  Usage:
#    bash <(curl -fsSL https://raw.githubusercontent.com/0OZ/init-server/main/init.sh)
#
#  Flags:
#    --version, -v   Print script version
#    --check         Compare local vs remote version
# ============================================================

set -euo pipefail

# --- Script version ---
SCRIPT_VERSION="1.1.0"
SCRIPT_REPO="0OZ/init-server"
SCRIPT_RAW="https://raw.githubusercontent.com/${SCRIPT_REPO}/main/init.sh"

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; }
header(){ echo -e "\n${BOLD}── $* ──${NC}"; }
ver()   { echo -e "  ${DIM}$1${NC} $2"; }

# --- --version / --check flags ---
if [[ "${1:-}" == "--version" || "${1:-}" == "-v" ]]; then
    echo "init-server v${SCRIPT_VERSION}"
    exit 0
fi

if [[ "${1:-}" == "--check" ]]; then
    echo "Local:  v${SCRIPT_VERSION}"
    REMOTE_VER=$(curl -fsSL "$SCRIPT_RAW" 2>/dev/null | grep -m1 '^SCRIPT_VERSION=' | cut -d'"' -f2)
    if [[ -n "$REMOTE_VER" ]]; then
        echo "Remote: v${REMOTE_VER}"
        if [[ "$SCRIPT_VERSION" == "$REMOTE_VER" ]]; then
            info "Up to date."
        else
            warn "Update available! Run:"
            echo "  bash <(curl -fsSL ${SCRIPT_RAW})"
        fi
    else
        warn "Could not fetch remote version."
    fi
    exit 0
fi

# --- Must run as root ---
if [[ $EUID -ne 0 ]]; then
    error "Please run as root:"
    echo "  bash <(curl -fsSL https://raw.githubusercontent.com/0OZ/init-server/main/init.sh)"
    exit 1
fi

# --- Detect SSH service name (ssh on Ubuntu 24.04+, sshd on older) ---
if systemctl is-active ssh &>/dev/null || [[ -f /lib/systemd/system/ssh.service ]]; then
    SSH_SERVICE="ssh"
else
    SSH_SERVICE="sshd"
fi

# ============================================================
# 0. Resolve / create the non-root user
# ============================================================
header "User Setup"

REAL_USER="${SUDO_USER:-}"
if [[ -z "$REAL_USER" || "$REAL_USER" == "root" ]]; then
    read -rp "Enter the non-root username to configure: " REAL_USER
fi

if ! id "$REAL_USER" &>/dev/null; then
    warn "User '${REAL_USER}' does not exist."
    read -rp "Create user '${REAL_USER}' with sudo access? [y/N] " CREATE_CONFIRM
    if [[ "${CREATE_CONFIRM,,}" != "y" ]]; then
        error "Aborted. Create the user manually first, then re-run."
        exit 1
    fi

    adduser --disabled-password --gecos "" "$REAL_USER"
    usermod -aG sudo "$REAL_USER"

    # Passwordless sudo (password login is disabled entirely)
    echo "${REAL_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${REAL_USER}"
    chmod 440 "/etc/sudoers.d/${REAL_USER}"
    info "User '${REAL_USER}' created with sudo access."

    # --- Copy SSH keys from root → new user ---
    REAL_HOME=$(eval echo "~${REAL_USER}")
    mkdir -p "${REAL_HOME}/.ssh"

    if [[ -s /root/.ssh/authorized_keys ]]; then
        cp /root/.ssh/authorized_keys "${REAL_HOME}/.ssh/authorized_keys"
        info "Copied root's SSH keys → ${REAL_USER}"
    else
        warn "No SSH keys found on root either."
        echo ""
        echo "  Paste your public SSH key (one line), then press Enter:"
        read -r SSH_KEY
        if [[ -z "$SSH_KEY" ]]; then
            error "No key provided. Cannot continue without SSH access."
            exit 1
        fi
        echo "$SSH_KEY" > "${REAL_HOME}/.ssh/authorized_keys"
        info "SSH key added for '${REAL_USER}'."
    fi

    chmod 700 "${REAL_HOME}/.ssh"
    chmod 600 "${REAL_HOME}/.ssh/authorized_keys"
    chown -R "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/.ssh"
else
    info "User '${REAL_USER}' already exists."
    REAL_HOME=$(eval echo "~${REAL_USER}")
fi

# --- Pre-flight: SSH key check ---
AUTH_KEYS="${REAL_HOME}/.ssh/authorized_keys"
if [[ ! -s "$AUTH_KEYS" ]]; then
    error "No SSH keys found in ${AUTH_KEYS}"
    error "Add your public key BEFORE running this script, or you WILL lock yourself out!"
    exit 1
fi
info "SSH key(s) detected for '${REAL_USER}' — safe to proceed."

echo ""
echo "========================================"
echo "  init-server v${SCRIPT_VERSION}"
echo "  github.com/${SCRIPT_REPO}"
echo "========================================"

# --- Check for newer script version ---
REMOTE_VER=$(curl -fsSL --connect-timeout 3 "$SCRIPT_RAW" 2>/dev/null \
    | grep -m1 '^SCRIPT_VERSION=' | cut -d'"' -f2 || true)
if [[ -n "$REMOTE_VER" && "$REMOTE_VER" != "$SCRIPT_VERSION" ]]; then
    warn "Script update available: v${SCRIPT_VERSION} → v${REMOTE_VER}"
    warn "Re-run with: bash <(curl -fsSL ${SCRIPT_RAW})"
    read -rp "Continue with current version anyway? [Y/n] " UPDATE_CONFIRM
    if [[ "${UPDATE_CONFIRM,,}" == "n" ]]; then
        exit 0
    fi
else
    info "Script is up to date (v${SCRIPT_VERSION})."
fi

# ============================================================
# 1. System update
# ============================================================
header "System Update"
apt-get update -qq
apt-get upgrade -y -qq
info "System packages updated."

# ============================================================
# 2. Fish shell
# ============================================================
header "Fish Shell"
apt-get install -y -qq fish

FISH_PATH=$(which fish)
if ! grep -q "$FISH_PATH" /etc/shells; then
    echo "$FISH_PATH" >> /etc/shells
fi
chsh -s "$FISH_PATH" "$REAL_USER"
info "Fish installed and set as default shell for '${REAL_USER}'."

# ============================================================
# 3. fail2ban
# ============================================================
header "fail2ban"
PYTHONWARNINGS=ignore apt-get install -y -qq fail2ban

cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 15m
findtime = 10m
maxretry = 5

# Repeat offenders get progressively longer bans automatically.
# First ban = 15m, then doubles each time the same IP re-offends,
# capped at 24h. Honest mistakes stay cheap; brute-forcers get hammered.
bantime.increment = true
bantime.factor    = 2
bantime.maxtime   = 24h

# Never ban localhost
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = %(sshd_log)s
backend  = %(sshd_backend)s
maxretry = 5
bantime  = 15m
EOF

systemctl enable fail2ban
systemctl restart fail2ban
info "fail2ban enabled with SSH jail (5 attempts → 15m ban, escalating)."

# ============================================================
# 4. SSH hardening
# ============================================================
header "SSH Hardening"

SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_HARDENING="/etc/ssh/sshd_config.d/99-hardening.conf"

cat > "$SSHD_HARDENING" <<'EOF'
# --- Server hardening (managed by setup script) ---
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
EOF

if ! grep -q "^Include /etc/ssh/sshd_config.d/" "$SSHD_CONFIG"; then
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$SSHD_CONFIG"
fi

if sshd -t; then
    systemctl restart "$SSH_SERVICE"
    info "SSH hardened — root login & password auth disabled."
else
    error "SSH config validation failed! Reverting."
    rm -f "$SSHD_HARDENING"
    exit 1
fi

# ============================================================
# 5. Docker + Docker Compose (official repo)
# ============================================================
header "Docker"

# Install prerequisites
apt-get install -y -qq ca-certificates curl gnupg

# Add Docker's official GPG key
install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
fi

# Add the Docker repo
UBUNTU_CODENAME=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable
EOF

apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Let the user run docker without sudo
usermod -aG docker "$REAL_USER"

systemctl enable docker
systemctl start docker
info "Docker + Docker Compose installed. '${REAL_USER}' added to docker group."

# ============================================================
# 6. GitHub CLI + private repo access
# ============================================================
header "GitHub"

# Install gh CLI from official repo
if ! command -v gh &>/dev/null; then
    (type -p wget >/dev/null || apt-get install -y -qq wget)
    mkdir -p -m 755 /etc/apt/keyrings
    out=$(wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg) \
        && echo "$out" | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | tee /etc/apt/sources.list.d/github-cli-stable.list >/dev/null
    apt-get update -qq
    apt-get install -y -qq gh
fi
info "GitHub CLI (gh) installed."

# Optional: configure token for private repos
GH_CONFIGURED=false
echo ""
read -rp "Configure a GitHub token for private repos? [y/N] " GH_CONFIRM
if [[ "${GH_CONFIRM,,}" == "y" ]]; then
    echo ""
    echo "  Create a token at: https://github.com/settings/tokens"
    echo "  Scopes needed: repo, read:org (Fine-grained: Contents read)"
    echo ""
    read -rsp "  Paste your GitHub token (hidden): " GH_TOKEN
    echo ""

    if [[ -n "$GH_TOKEN" ]]; then
        # Auth gh CLI (configures git credential helper automatically)
        su - "$REAL_USER" -s /bin/bash -c "echo '${GH_TOKEN}' | gh auth login --with-token"

        # Also set git to use gh as credential helper (works for git clone https://...)
        su - "$REAL_USER" -s /bin/bash -c "gh auth setup-git"

        # Set git identity if not already configured
        EXISTING_NAME=$(su - "$REAL_USER" -s /bin/bash -c "git config --global user.name" 2>/dev/null || true)
        if [[ -z "$EXISTING_NAME" ]]; then
            echo ""
            read -rp "  Git name  (e.g. 'Oz'): " GIT_NAME
            read -rp "  Git email (e.g. 'oz@example.com'): " GIT_EMAIL
            su - "$REAL_USER" -s /bin/bash -c "git config --global user.name '${GIT_NAME}'"
            su - "$REAL_USER" -s /bin/bash -c "git config --global user.email '${GIT_EMAIL}'"
        fi

        GH_CONFIGURED=true
        info "GitHub authenticated. 'git clone' works with private repos."
    else
        warn "Empty token — skipped GitHub auth."
    fi
else
    info "Skipped GitHub token (you can run 'gh auth login' later)."
fi

# ============================================================
# 7. Claude Code (native installer)
# ============================================================
header "Claude Code"
su - "$REAL_USER" -s /bin/bash -c 'curl -fsSL https://claude.ai/install.sh | bash'

FISH_CONFIG="${REAL_HOME}/.config/fish/config.fish"
mkdir -p "$(dirname "$FISH_CONFIG")"
if [[ ! -f "$FISH_CONFIG" ]] || ! grep -q '.local/bin' "$FISH_CONFIG"; then
    echo 'fish_add_path -g $HOME/.local/bin' >> "$FISH_CONFIG"
fi
chown -R "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/.config"
info "Claude Code installed."

# ============================================================
# 8. Extras (curl, git, htop, ufw)
# ============================================================
header "Extras"
apt-get install -y -qq curl git htop ufw

if ! ufw status | grep -q "active"; then
    ufw allow OpenSSH
    ufw --force enable
fi
info "UFW firewall enabled (SSH allowed)."

# ============================================================
# 9. Cleanup
# ============================================================
header "Cleanup"
apt-get autoremove -y -qq
apt-get clean -qq
info "Package cache cleaned."

# ============================================================
# 10. HEALTH CHECK
# ============================================================
echo ""
echo "========================================"
echo -e "  ${BOLD}Health Check${NC}"
echo "========================================"
echo ""

CHECKS_PASSED=0
CHECKS_FAILED=0

check() {
    local label="$1"
    shift
    if eval "$@" &>/dev/null; then
        info "$label"
        ((CHECKS_PASSED++))
    else
        error "$label"
        ((CHECKS_FAILED++))
    fi
}

# --- User ---
check "User '${REAL_USER}' exists"            "id '${REAL_USER}'"
check "User has sudo access"                   "groups '${REAL_USER}' | grep -q sudo"

# --- Fish ---
check "Fish installed"                         "which fish"
check "Fish is default shell for ${REAL_USER}" \
    "getent passwd '${REAL_USER}' | grep -q fish"

# --- fail2ban ---
check "fail2ban service running"               "systemctl is-active --quiet fail2ban"
check "fail2ban SSH jail active" \
    "fail2ban-client status sshd 2>/dev/null | grep -q 'Status for the jail: sshd'"

# --- SSH ---
check "SSH service (${SSH_SERVICE}) running"   "systemctl is-active --quiet '${SSH_SERVICE}'"
check "PasswordAuthentication disabled" \
    "sshd -T 2>/dev/null | grep -qi 'passwordauthentication no'"
check "PermitRootLogin disabled" \
    "sshd -T 2>/dev/null | grep -qi 'permitrootlogin no'"
check "SSH key exists for ${REAL_USER}" \
    "test -s '${REAL_HOME}/.ssh/authorized_keys'"

# --- Docker ---
check "Docker daemon running"                  "systemctl is-active --quiet docker"
check "Docker CLI works"                       "docker --version"
check "Docker Compose available"               "docker compose version"
check "User in docker group" \
    "groups '${REAL_USER}' | grep -q docker"

# --- GitHub ---
check "GitHub CLI installed"                   "which gh"
if [[ "$GH_CONFIGURED" == true ]]; then
    check "GitHub auth active" \
        "su - '${REAL_USER}' -s /bin/bash -c 'gh auth status' 2>&1 | grep -q 'Logged in'"
fi

# --- Claude Code ---
check "Claude Code binary exists" \
    "test -f '${REAL_HOME}/.local/bin/claude'"

# --- UFW ---
check "UFW active"                             "ufw status | grep -q 'Status: active'"
check "UFW allows SSH"                         "ufw status | grep -q 'OpenSSH'"

# --- Clean system ---
check "No pending security updates" \
    "! apt list --upgradable 2>/dev/null | grep -qi 'security'"

# --- Summary ---
TOTAL=$((CHECKS_PASSED + CHECKS_FAILED))
echo ""
echo "========================================"
if [[ $CHECKS_FAILED -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}All ${TOTAL}/${TOTAL} checks passed ✓${NC}"
else
    echo -e "  ${GREEN}${CHECKS_PASSED} passed${NC} / ${RED}${CHECKS_FAILED} failed${NC}  (${TOTAL} total)"
fi
echo "========================================"

# --- Version Report ---
echo ""
echo -e "  ${BOLD}Versions:${NC}"

get_ver() {
    local val
    val=$( eval "$2" 2>/dev/null ) || val="not found"
    printf "    %-20s %s\n" "$1" "$val"
}

get_ver "Ubuntu"          "lsb_release -ds"
get_ver "Kernel"          "uname -r"
get_ver "Fish"            "fish --version | awk '{print \$NF}'"
get_ver "fail2ban"        "fail2ban-client --version | head -1 | awk '{print \$NF}'"
get_ver "OpenSSH"         "ssh -V 2>&1 | awk '{print \$1}'"
get_ver "Docker"          "docker --version | grep -oP 'Docker version \K[^,]+'"
get_ver "Docker Compose"  "docker compose version --short"
get_ver "Docker Buildx"   "docker buildx version | awk '{print \$2}'"
get_ver "GitHub CLI"      "gh --version | head -1 | awk '{print \$3}'"
get_ver "Claude Code"     "su - '${REAL_USER}' -s /bin/bash -c '~/.local/bin/claude --version' 2>/dev/null || echo 'installed'"
get_ver "UFW"             "ufw version | awk '{print \$NF}'"
get_ver "Git"             "git --version | awk '{print \$NF}'"
get_ver "init-server"     "echo v${SCRIPT_VERSION}"
echo ""
echo "  Next steps:"
echo "    1. Open a NEW terminal:  ssh ${REAL_USER}@<this-server>"
echo "    2. Verify you get a fish prompt"
echo "    3. Run 'claude' to authenticate Claude Code"
echo "    4. Test docker:  docker run --rm hello-world"
echo "    5. Test GitHub:  gh repo list --limit 3"
echo ""
warn "DO NOT close this session until you confirm SSH access in another terminal!"

exit "$CHECKS_FAILED"
