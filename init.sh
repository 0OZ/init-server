#!/usr/bin/env bash
# ============================================================
#  Fresh Ubuntu Server Setup
#  Installs: fish shell, fail2ban, Claude Code
#  Configures: SSH key-only auth (disables root password login)
#
#  Usage (one-liner from GitHub):
#    sudo bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/setup-server.sh)
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
    error "Please run as root:  sudo bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/setup-server.sh)"
    exit 1
fi

# --- Resolve the real (non-root) user ---
REAL_USER="${SUDO_USER:-}"
if [[ -z "$REAL_USER" || "$REAL_USER" == "root" ]]; then
    # When piped via curl, SUDO_USER may be empty — prompt for it
    read -rp "Enter the non-root username to configure: " REAL_USER
    if ! id "$REAL_USER" &>/dev/null; then
        error "User '${REAL_USER}' does not exist."
        exit 1
    fi
fi
REAL_HOME=$(eval echo "~${REAL_USER}")

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
echo ""

# ============================================================
# 1. System update
# ============================================================
header "System Update"
apt-get update -qq
apt-get upgrade -y -qq
info "System packages updated."

# ============================================================
# 2. Install Fish shell
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
# 3. Install & configure fail2ban
# ============================================================
header "fail2ban"
apt-get install -y -qq fail2ban

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
# 4. Harden SSH
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
    systemctl restart sshd
    info "SSH hardened — root login & password auth disabled."
else
    error "SSH config validation failed! Reverting."
    rm -f "$SSHD_HARDENING"
    exit 1
fi

# ============================================================
# 5. Install Claude Code (native installer)
# ============================================================
header "Claude Code"
su - "$REAL_USER" -s /bin/bash -c 'curl -fsSL https://claude.ai/install.sh | bash'

FISH_CONFIG="${REAL_HOME}/.config/fish/config.fish"
mkdir -p "$(dirname "$FISH_CONFIG")"
if [[ ! -f "$FISH_CONFIG" ]] || ! grep -q '.local/bin' "$FISH_CONFIG"; then
    echo 'fish_add_path -g $HOME/.local/bin' >> "$FISH_CONFIG"
    chown "$REAL_USER":"$REAL_USER" "$FISH_CONFIG"
fi
info "Claude Code installed."

# ============================================================
# 6. Extras (curl, git, htop, ufw)
# ============================================================
header "Extras"
apt-get install -y -qq curl git htop ufw

if ! ufw status | grep -q "active"; then
    ufw allow OpenSSH
    ufw --force enable
fi
info "UFW firewall enabled (SSH allowed)."

# ============================================================
# 7. Cleanup
# ============================================================
header "Cleanup"
apt-get autoremove -y -qq
apt-get clean -qq
info "Package cache cleaned."

# ============================================================
# 8. HEALTH CHECK
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

# --- Fish ---
check "Fish installed"                      "which fish"
check "Fish is default shell for ${REAL_USER}" \
    "getent passwd '${REAL_USER}' | grep -q fish"

# --- fail2ban ---
check "fail2ban service running"            "systemctl is-active --quiet fail2ban"
check "fail2ban SSH jail active" \
    "fail2ban-client status sshd 2>/dev/null | grep -q 'Status for the jail: sshd'"

# --- SSH ---
check "PasswordAuthentication disabled" \
    "sshd -T 2>/dev/null | grep -qi 'passwordauthentication no'"
check "PermitRootLogin disabled" \
    "sshd -T 2>/dev/null | grep -qi 'permitrootlogin no'"

# --- Claude Code ---
check "Claude Code binary exists" \
    "test -f '${REAL_HOME}/.local/bin/claude'"

# --- UFW ---
check "UFW active"                          "ufw status | grep -q 'Status: active'"
check "UFW allows SSH"                      "ufw status | grep -q 'OpenSSH'"

# --- Clean system ---
check "No pending security updates" \
    "! apt list --upgradable 2>/dev/null | grep -qi 'security'"

# --- Summary ---
echo ""
echo "========================================"
if [[ $CHECKS_FAILED -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}All ${CHECKS_PASSED}/${CHECKS_PASSED} checks passed ✓${NC}"
else
    echo -e "  ${GREEN}${CHECKS_PASSED} passed${NC} / ${RED}${CHECKS_FAILED} failed${NC}"
fi
echo "========================================"

echo ""
echo "  Next steps:"
echo "    1. Open a NEW terminal and verify SSH key login"
echo "    2. Run 'claude' to authenticate Claude Code"
echo "    3. Optionally reboot:  sudo reboot"
echo ""
warn "DO NOT close this session until you confirm SSH access in another terminal!"

exit "$CHECKS_FAILED"