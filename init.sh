#!/usr/bin/env bash
# ============================================================
#  Fresh Ubuntu Server Setup
#  Installs: fish, fail2ban, docker, docker compose, claude code
#  Configures: SSH key-only auth, UFW firewall, new sudo user
#
#  Usage:
#    bash <(curl -fsSL https://raw.githubusercontent.com/0OZ/init-server/main/init.sh)
# ============================================================

set -euo pipefail

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; }
header(){ echo -e "\n${BOLD}── $* ──${NC}"; }

# --- Must run as root ---
if [[ $EUID -ne 0 ]]; then
    error "Please run as root:"
    echo "  bash <(curl -fsSL https://raw.githubusercontent.com/0OZ/init-server/main/init.sh)"
    exit 1
fi

# --- Detect SSH service name (ssh on Ubuntu 24.04+, sshd on older) ---
if systemctl list-unit-files ssh.service &>/dev/null && systemctl cat ssh.service &>/dev/null; then
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
echo "  Starting Ubuntu Server Setup"
echo "========================================"

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
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = %(sshd_log)s
backend  = %(sshd_backend)s
maxretry = 3
bantime  = 3h
EOF

systemctl enable fail2ban
systemctl restart fail2ban
info "fail2ban enabled with SSH jail (3 attempts → 3h ban)."

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
# 6. Claude Code (native installer)
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
# 7. Extras (curl, git, htop, ufw)
# ============================================================
header "Extras"
apt-get install -y -qq curl git htop ufw

if ! ufw status | grep -q "active"; then
    ufw allow OpenSSH
    ufw --force enable
fi
info "UFW firewall enabled (SSH allowed)."

# ============================================================
# 8. Cleanup
# ============================================================
header "Cleanup"
apt-get autoremove -y -qq
apt-get clean -qq
info "Package cache cleaned."

# ============================================================
# 9. HEALTH CHECK
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

echo ""
echo "  Installed:"
echo "    • Fish shell (default for ${REAL_USER})"
echo "    • fail2ban (SSH jail active)"
echo "    • Docker $(docker --version 2>/dev/null | grep -oP 'Docker version \K[^,]+')"
echo "    • Docker Compose $(docker compose version 2>/dev/null | grep -oP 'v[\d.]+')"
echo "    • Claude Code"
echo "    • UFW firewall"
echo ""
echo "  Next steps:"
echo "    1. Open a NEW terminal:  ssh ${REAL_USER}@<this-server>"
echo "    2. Verify you get a fish prompt"
echo "    3. Run 'claude' to authenticate Claude Code"
echo "    4. Test docker:  docker run --rm hello-world"
echo ""
warn "DO NOT close this session until you confirm SSH access in another terminal!"

exit "$CHECKS_FAILED"