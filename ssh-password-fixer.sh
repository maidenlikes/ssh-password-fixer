#!/usr/bin/env bash
#
# SSH Password Login Fixer (+ root password setter)
# ------------------------------------------------------------
# Safely enables SSH password authentication on
# Ubuntu Server (22.04 / 24.04), then sets the root password.
#
# Flow:
#   root check -> openssh check -> detect config -> backup ->
#   fix PasswordAuthentication + PermitRootLogin -> sshd -t ->
#   restart ssh -> sshd -T verify -> set root password
#
# IMPORTANT:
#   For root login via password, PermitRootLogin must be 'yes'.
#   This script does NOT reboot and does NOT delete SSH keys by itself.
#
# Usage (local file):
#   sudo bash ssh-password-fixer.sh            # interactive mode (menu)
#   sudo bash ssh-password-fixer.sh --fix      # automatic fix + set password
#   sudo bash ssh-password-fixer.sh --check    # check only, no changes
#   sudo bash ssh-password-fixer.sh --restore  # restore from backup
#   sudo bash ssh-password-fixer.sh --remove-keys  # remove SSH keys (password-only)
#
# Usage (straight from the internet / curl-bash, no file transfer):
#   bash <(curl -fsSL https://URL/ssh-password-fixer.sh) --fix
# Interactive prompts read from /dev/tty so they still work through this pipe.
# ------------------------------------------------------------

set -o pipefail

# ----------------------------- Colors -----------------------------
if [ -t 1 ]; then
    C_RESET="\033[0m"
    C_RED="\033[0;31m"
    C_GREEN="\033[0;32m"
    C_YELLOW="\033[0;33m"
    C_BLUE="\033[0;34m"
    C_BOLD="\033[1m"
else
    C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""
fi

# ----------------------------- Constants -----------------------------
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_CONFIG_DIR="/etc/ssh/sshd_config.d"
DROPIN_FILE="${SSHD_CONFIG_DIR}/99-password-auth.conf"
BACKUP_ROOT="/var/backups/ssh-password-fixer"

# SSH service name (ssh vs sshd depending on the distro)
SSH_SERVICE="ssh"

# ----------------------------- Helper output -----------------------------
banner() {
    echo -e "${C_BOLD}========================================${C_RESET}"
    echo -e "${C_BOLD}       SSH PASSWORD LOGIN FIXER${C_RESET}"
    echo -e "${C_BOLD}========================================${C_RESET}"
    echo
}

info()    { echo -e "${C_BLUE}[+]${C_RESET} $*"; }
ok()      { echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
warn()    { echo -e "${C_YELLOW}[!]${C_RESET} $*"; }
err()     { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

# ----------------------------- Input helpers -----------------------------
# Read input directly from the terminal (/dev/tty), not stdin.
# This matters so prompts still work when the script is run via
# curl-bash, e.g. bash <(curl -fsSL URL) --fix
# In that pattern stdin is already used to stream the script body.

# Make sure a terminal is available for interactive prompts.
require_tty() {
    if [ ! -e /dev/tty ]; then
        err "This mode needs an interactive terminal (no /dev/tty)."
        echo "Run it directly in the VPS terminal, or download first then run:" >&2
        echo "  curl -fsSL URL -o fix.sh && bash fix.sh --fix" >&2
        exit 1
    fi
}

# ask "Pertanyaan: " VAR  -> input biasa
ask() {
    local prompt="$1" __var="$2" __val
    read -r -p "$prompt" __val </dev/tty
    printf -v "$__var" '%s' "$__val"
}

# ask_secret "Pertanyaan: " VAR -> input tersembunyi (password)
ask_secret() {
    local prompt="$1" __var="$2" __val
    read -r -s -p "$prompt" __val </dev/tty
    echo
    printf -v "$__var" '%s' "$__val"
}

# ----------------------------- Step 1: Root check -----------------------------
check_root() {
    info "Checking permissions..."
    if [ "$(id -u)" -ne 0 ]; then
        err "Root privileges are required."
        echo
        echo "Run:"
        echo "  sudo bash $0"
        exit 1
    fi
    ok "Running as root."
    echo
}

# ----------------------------- Step 2: OpenSSH check -----------------------------
check_openssh() {
    info "Checking OpenSSH..."
    if ! command -v sshd >/dev/null 2>&1; then
        err "OpenSSH Server is not installed."
        exit 1
    fi
    ok "OpenSSH detected."
    echo

    # Detect the service name (ssh or sshd)
    if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
        SSH_SERVICE="ssh"
    elif systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service'; then
        SSH_SERVICE="sshd"
    fi
}

# ----------------------------- Step 3: Detect configuration -----------------------------
detect_config() {
    info "Checking configuration..."
    echo
    echo "SSH configuration detected:"
    echo

    local found_any=0

    if [ -f "$SSHD_CONFIG" ]; then
        local line
        line=$(grep -iE '^\s*PasswordAuthentication\s+' "$SSHD_CONFIG" 2>/dev/null)
        if [ -n "$line" ]; then
            echo "  $SSHD_CONFIG"
            echo "$line" | while IFS= read -r l; do echo "    $(echo "$l" | xargs)"; done
            found_any=1
        fi
    fi

    if [ -d "$SSHD_CONFIG_DIR" ]; then
        local f
        for f in "$SSHD_CONFIG_DIR"/*.conf; do
            [ -e "$f" ] || continue
            local line
            line=$(grep -iE '^\s*PasswordAuthentication\s+' "$f" 2>/dev/null)
            if [ -n "$line" ]; then
                echo "  $f"
                echo "$line" | while IFS= read -r l; do echo "    $(echo "$l" | xargs)"; done
                found_any=1
            fi
        done
    fi

    if [ "$found_any" -eq 0 ]; then
        echo "  (No explicit PasswordAuthentication directive found)"
    fi
    echo
}

# ----------------------------- Step 4: Effective config -----------------------------
effective_config() {
    info "Checking effective configuration..."
    echo

    local pa pk am
    pa=$(sshd -T 2>/dev/null | grep -i '^passwordauthentication' | awk '{print $2}')
    pk=$(sshd -T 2>/dev/null | grep -i '^pubkeyauthentication' | awk '{print $2}')
    am=$(sshd -T 2>/dev/null | grep -i '^authenticationmethods' | awk '{print $2}')

    echo "    PasswordAuthentication: ${pa:-unknown}"
    echo "    PubkeyAuthentication:   ${pk:-unknown}"
    echo "    AuthenticationMethods:  ${am:-any}"
    echo

    EFFECTIVE_PASSWORD_AUTH="$pa"
}

# ----------------------------- Step 6: Backup -----------------------------
create_backup() {
    info "Creating backup..."
    local ts backup_dir
    ts=$(date +%Y-%m-%d_%H%M%S)
    backup_dir="${BACKUP_ROOT}/${ts}"

    if ! mkdir -p "$backup_dir" 2>/dev/null; then
        err "Unable to create backup."
        warn "No configuration changes were made."
        exit 1
    fi

    if [ -f "$SSHD_CONFIG" ]; then
        cp -a "$SSHD_CONFIG" "$backup_dir/" 2>/dev/null || {
            err "Unable to create backup."
            warn "No configuration changes were made."
            exit 1
        }
    fi

    if [ -d "$SSHD_CONFIG_DIR" ]; then
        cp -a "$SSHD_CONFIG_DIR" "$backup_dir/" 2>/dev/null || {
            err "Unable to create backup."
            warn "No configuration changes were made."
            exit 1
        }
    fi

    LAST_BACKUP_DIR="$backup_dir"
    ok "Backup created: $backup_dir"
    echo
}

# ----------------------------- Step 7: Fix konfigurasi -----------------------------
apply_fix() {
    info "Applying configuration..."

    # 1. Turn 'PasswordAuthentication no' in the main file & drop-ins into 'yes'.
    #    We rewrite any line that sets it to 'no'.
    _fix_file_password_auth "$SSHD_CONFIG"

    if [ -d "$SSHD_CONFIG_DIR" ]; then
        local f
        for f in "$SSHD_CONFIG_DIR"/*.conf; do
            [ -e "$f" ] || continue
            # Don't touch our own drop-in in this loop
            [ "$f" = "$DROPIN_FILE" ] && continue
            _fix_file_password_auth "$f"
        done
    fi

    # 2. Create a high-priority drop-in so the effective value is guaranteed 'yes'.
    #    Drop-ins are read in alphabetical order; '99-' makes it win.
    mkdir -p "$SSHD_CONFIG_DIR" 2>/dev/null
    cat > "$DROPIN_FILE" <<'EOF'
# Managed by ssh-password-fixer
# Enables password login + root login via password.
# SSH key authentication is preserved.
PasswordAuthentication yes
PubkeyAuthentication yes
PermitRootLogin yes
EOF

    ok "PasswordAuthentication enabled."
    ok "PermitRootLogin set to yes (required for root login via password)."
    echo
}

# Change 'PasswordAuthentication no' -> 'yes' in a file.
# Also make sure no active 'PermitRootLogin no/prohibit-password' remains.
_fix_file_password_auth() {
    local file="$1"
    [ -f "$file" ] || return 0

    # PasswordAuthentication no|yes  -> yes
    sed -i -E 's/^\s*#?\s*(PasswordAuthentication)\s+.*/\1 yes/I' "$file"

    # Any PermitRootLogin -> yes (only if the directive already exists in the file)
    if grep -iqE '^\s*#?\s*PermitRootLogin\s+' "$file"; then
        sed -i -E 's/^\s*#?\s*(PermitRootLogin)\s+.*/\1 yes/I' "$file"
    fi
}

# ----------------------------- Step 8: Validasi -----------------------------
validate_config() {
    info "Validating configuration..."
    if sshd -t 2>/tmp/sshd_test_err; then
        ok "sshd configuration is valid."
        echo
        return 0
    else
        err "sshd configuration validation failed."
        warn "SSH service was NOT restarted."
        echo
        cat /tmp/sshd_test_err >&2
        echo
        warn "Rolling back changes..."
        rollback
        exit 1
    fi
}

rollback() {
    if [ -n "$LAST_BACKUP_DIR" ] && [ -d "$LAST_BACKUP_DIR" ]; then
        [ -f "$LAST_BACKUP_DIR/sshd_config" ] && cp -a "$LAST_BACKUP_DIR/sshd_config" "$SSHD_CONFIG"
        if [ -d "$LAST_BACKUP_DIR/sshd_config.d" ]; then
            rm -rf "$SSHD_CONFIG_DIR"
            cp -a "$LAST_BACKUP_DIR/sshd_config.d" "$SSHD_CONFIG_DIR"
        else
            # If the backup has no drop-in folder, at least remove our drop-in
            rm -f "$DROPIN_FILE"
        fi
        ok "Changes have been rolled back from: $LAST_BACKUP_DIR"
    else
        warn "No backup available to roll back."
    fi
}

# ----------------------------- Step 9: Restart SSH -----------------------------
restart_ssh() {
    info "Restarting SSH..."
    if systemctl restart "$SSH_SERVICE" 2>/tmp/ssh_restart_err; then
        ok "SSH service restarted."
        echo
        return 0
    else
        err "SSH service failed to restart."
        echo
        echo "Your existing SSH session has not been terminated."
        echo
        echo "Check:"
        echo "  systemctl status $SSH_SERVICE"
        echo "  journalctl -u $SSH_SERVICE"
        echo
        cat /tmp/ssh_restart_err >&2
        exit 1
    fi
}

# ----------------------------- Step 10: Verifikasi -----------------------------
verify_config() {
    info "Verifying effective configuration..."
    echo

    local pa pk am rl
    pa=$(sshd -T 2>/dev/null | grep -i '^passwordauthentication' | awk '{print $2}')
    pk=$(sshd -T 2>/dev/null | grep -i '^pubkeyauthentication' | awk '{print $2}')
    am=$(sshd -T 2>/dev/null | grep -i '^authenticationmethods' | awk '{print $2}')
    rl=$(sshd -T 2>/dev/null | grep -i '^permitrootlogin' | awk '{print $2}')

    echo "    PasswordAuthentication: ${pa:-unknown}"
    echo "    PubkeyAuthentication:   ${pk:-unknown}"
    echo "    PermitRootLogin:        ${rl:-unknown}"
    echo "    AuthenticationMethods:  ${am:-any}"
    echo

    info "Checking SSH service..."
    if [ "$(systemctl is-active "$SSH_SERVICE" 2>/dev/null)" = "active" ]; then
        ok "SSH service is active."
    else
        warn "SSH service is not active."
    fi
    echo
}

# ----------------------------- Set root password -----------------------------
set_root_password() {
    echo -e "${C_BOLD}----------------------------------------${C_RESET}"
    echo -e "${C_BOLD}       SET ROOT PASSWORD${C_RESET}"
    echo -e "${C_BOLD}----------------------------------------${C_RESET}"
    echo

    require_tty
    local pass1 pass2
    while true; do
        ask_secret "Please enter the password you want for (root) : " pass1
        if [ -z "$pass1" ]; then
            warn "Password cannot be empty. Try again."
            continue
        fi
        ask_secret "Repeat the password for (root) : " pass2
        if [ "$pass1" != "$pass2" ]; then
            warn "Passwords do not match. Try again."
            echo
            continue
        fi
        break
    done

    if echo "root:${pass1}" | chpasswd; then
        ok "Root password set successfully."
    else
        err "Failed to set root password."
        return 1
    fi
    echo
}

# ----------------------------- Remove SSH keys -----------------------------
# Back up then empty authorized_keys for root and every user that has a home
# directory. After this, login is ONLY possible via password.
remove_ssh_keys() {
    echo -e "${C_BOLD}----------------------------------------${C_RESET}"
    echo -e "${C_BOLD}       REMOVE SSH KEYS${C_RESET}"
    echo -e "${C_BOLD}----------------------------------------${C_RESET}"
    echo
    echo -e "${C_YELLOW}WARNING:${C_RESET} This will remove all authorized_keys."
    echo "After this, the only way to log in is via password."
    echo "Make sure password login has been TESTED from another device."
    echo

    local ts backup_dir
    ts=$(date +%Y-%m-%d_%H%M%S)
    backup_dir="${BACKUP_ROOT}/keys_${ts}"

    if ! mkdir -p "$backup_dir" 2>/dev/null; then
        err "Failed to create key backup. Aborting, no keys were removed."
        return 1
    fi

    # Collect candidate authorized_keys files
    local ak_files=()
    [ -f /root/.ssh/authorized_keys ] && ak_files+=("/root/.ssh/authorized_keys")

    local home line user
    while IFS=: read -r user _ _ _ _ home _; do
        [ -z "$home" ] && continue
        if [ -f "$home/.ssh/authorized_keys" ]; then
            ak_files+=("$home/.ssh/authorized_keys")
        fi
    done < /etc/passwd

    if [ "${#ak_files[@]}" -eq 0 ]; then
        warn "No authorized_keys found. Nothing to remove."
        return 0
    fi

    echo "authorized_keys that will be emptied:"
    local f
    for f in "${ak_files[@]}"; do
        echo "    $f"
    done
    echo

    require_tty
    local confirm
    ask "Type 'REMOVE' to confirm: " confirm
    echo
    if [ "$confirm" != "REMOVE" ]; then
        warn "Cancelled. No keys were removed."
        return 1
    fi

    # Back up then empty
    for f in "${ak_files[@]}"; do
        local safe
        safe=$(echo "$f" | sed 's#/#_#g')
        cp -a "$f" "$backup_dir/$safe" 2>/dev/null
        : > "$f"
        ok "Emptied: $f"
    done

    ok "Key backup saved to: $backup_dir"
    ok "All SSH keys removed. Login is now password-only."
    echo
}

# ----------------------------- Success banner -----------------------------
success_banner() {
    echo -e "${C_GREEN}${C_BOLD}========================================${C_RESET}"
    echo -e "${C_GREEN}${C_BOLD}              SUCCESS${C_RESET}"
    echo -e "${C_GREEN}${C_BOLD}========================================${C_RESET}"
    echo
    echo "Password authentication is now enabled (root + password)."
    echo
    echo -e "${C_YELLOW}WARNING:${C_RESET}"
    echo "Keep your current SSH session open until you successfully"
    echo "test password login from another session."
    echo
}

# ----------------------------- Restore mode -----------------------------
do_restore() {
    check_root
    if [ ! -d "$BACKUP_ROOT" ] || [ -z "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]; then
        err "No backups found in $BACKUP_ROOT"
        exit 1
    fi

    echo "Available backups:"
    echo
    local backups=() i=1
    while IFS= read -r d; do
        backups+=("$d")
        echo "  [$i] $(basename "$d")"
        i=$((i+1))
    done < <(find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d | sort -r)
    echo

    require_tty
    local sel
    ask "Select backup: " sel
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "${#backups[@]}" ]; then
        err "Invalid selection."
        exit 1
    fi

    LAST_BACKUP_DIR="${backups[$((sel-1))]}"
    rollback
    validate_config
    restart_ssh
    verify_config
    ok "Restore complete."
}

# ----------------------------- Check-only mode -----------------------------
do_check() {
    check_root
    check_openssh
    echo "SSH Configuration Check"
    echo
    if command -v sshd >/dev/null 2>&1; then
        echo "  OpenSSH: installed"
    fi
    effective_config
    detect_config

    if [ "$EFFECTIVE_PASSWORD_AUTH" = "yes" ]; then
        echo "Status:"
        echo "  Password authentication is ENABLED."
    else
        echo "Status:"
        echo "  Password authentication is disabled."
    fi
}

# ----------------------------- Fix mode -----------------------------
do_fix() {
    banner
    check_root
    check_openssh
    detect_config
    effective_config
    create_backup
    apply_fix
    validate_config
    restart_ssh
    verify_config
    set_root_password

    # Offer to remove SSH keys after password auth is active & password is set.
    echo -e "${C_YELLOW}Password auth is active. Optional: remove SSH keys.${C_RESET}"
    echo "Recommended: test password login from another device BEFORE removing keys."
    local ans
    ask "Remove all SSH keys now? (y/N): " ans
    echo
    case "$ans" in
        y|Y) remove_ssh_keys ;;
        *)   info "Skipping key removal. You can run it later: sudo bash $0 --remove-keys" ;;
    esac

    success_banner
}

# ----------------------------- Interactive menu -----------------------------
interactive_menu() {
    banner
    check_root
    check_openssh

    while true; do
        echo "[1] Check SSH configuration"
        echo "[2] Enable password authentication + set root password"
        echo "[3] Create configuration backup"
        echo "[4] Restore previous configuration"
        echo "[5] Verify SSH configuration"
        echo "[6] Remove SSH keys (password-only login)"
        echo "[7] Exit"
        echo
        local opt
        ask "Select option: " opt
        echo
        case "$opt" in
            1) effective_config; detect_config ;;
            2)
                detect_config
                effective_config
                create_backup
                apply_fix
                validate_config
                restart_ssh
                verify_config
                set_root_password
                success_banner
                ;;
            3) create_backup ;;
            4) do_restore ;;
            5) verify_config ;;
            6) remove_ssh_keys ;;
            7) echo "Bye."; exit 0 ;;
            *) warn "Invalid option." ;;
        esac
        echo
    done
}

# ----------------------------- Entry point -----------------------------
main() {
    case "${1:-}" in
        --fix)         do_fix ;;
        --check)       do_check ;;
        --restore)     do_restore ;;
        --remove-keys) check_root; check_openssh; remove_ssh_keys ;;
        "")            interactive_menu ;;
        *)
            echo "Usage: sudo bash $0 [--fix | --check | --restore | --remove-keys]"
            exit 1
            ;;
    esac
}

main "$@"
