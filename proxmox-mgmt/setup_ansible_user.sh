#!/usr/bin/env bash
#
# setup_ansible_user.sh
#
# Idempotently provisions an "ansible" automation account:
#   1. Creates the "ansible" user (if missing)
#   2. Creates the "unix_admin" group (if missing)
#   3. Adds "ansible" to "unix_admin" (if not already a member)
#   4. Creates /etc/sudoers.d/unix_admin with a passwordless sudo rule (if missing)
#   5. Verifies the user, group membership, and sudo permissions
#   6. Creates ~ansible/.ssh/authorized_keys with the provided public key (if missing)
#
# Safe to run multiple times. Must be run as root.
#
# Usage: sudo ./setup_ansible_user.sh

set -Eeuo pipefail
IFS=$'\n\t'

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
readonly USER_NAME="ansible"
readonly GROUP_NAME="unix_admin"
readonly SUDOERS_DIR="/etc/sudoers.d"
readonly SUDOERS_FILE="${SUDOERS_DIR}/${GROUP_NAME}"
readonly SUDOERS_RULE="%${GROUP_NAME} ALL=(ALL) NOPASSWD: ALL"
readonly SSH_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILbCU1AZ1R6U2GGkKT1l2/FohRDnCM5O/IGZfKLPSF3Z ansible"

TMP_FILE=""

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
log()  { printf '[%s] [INFO]  %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] [WARN]  %s\n' "$(date '+%F %T')" "$*" >&2; }
die()  { printf '[%s] [ERROR] %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }

cleanup() {
    if [[ -n "${TMP_FILE}" && -f "${TMP_FILE}" ]]; then
        rm -f -- "${TMP_FILE}"
    fi
}

on_error() {
    local exit_code=$?
    printf '[%s] [ERROR] Command failed (exit %d) at line %d: %s\n' \
        "$(date '+%F %T')" "${exit_code}" "${BASH_LINENO[0]}" "${BASH_COMMAND}" >&2
    exit "${exit_code}"
}

trap cleanup EXIT
trap on_error ERR

require_root() {
    [[ ${EUID} -eq 0 ]] || die "This script must be run as root (try: sudo $0)."
}

require_commands() {
    local cmd missing=()
    for cmd in "$@"; do
        command -v "${cmd}" &>/dev/null || missing+=("${cmd}")
    done
    if (( ${#missing[@]} > 0 )); then
        die "Missing required command(s): ${missing[*]}"
    fi
}

user_in_group() {
    local user=$1 group=$2
    [[ " $(id -nG "${user}") " == *" ${group} "* ]]
}

# ----------------------------------------------------------------------------
# Step 1: Ensure user exists
# ----------------------------------------------------------------------------
ensure_user() {
    if id -u "${USER_NAME}" &>/dev/null; then
        log "User '${USER_NAME}' already exists."
    else
        log "Creating user '${USER_NAME}'..."
        useradd --create-home --shell /bin/bash "${USER_NAME}"
        log "User '${USER_NAME}' created."
    fi
}

# ----------------------------------------------------------------------------
# Step 2: Ensure group exists
# ----------------------------------------------------------------------------
ensure_group() {
    if getent group "${GROUP_NAME}" &>/dev/null; then
        log "Group '${GROUP_NAME}' already exists."
    else
        log "Creating group '${GROUP_NAME}'..."
        groupadd "${GROUP_NAME}"
        log "Group '${GROUP_NAME}' created."
    fi
}

# ----------------------------------------------------------------------------
# Step 3: Ensure user is a member of the group
# ----------------------------------------------------------------------------
ensure_membership() {
    if user_in_group "${USER_NAME}" "${GROUP_NAME}"; then
        log "User '${USER_NAME}' is already a member of '${GROUP_NAME}'."
    else
        log "Adding '${USER_NAME}' to group '${GROUP_NAME}'..."
        usermod --append --groups "${GROUP_NAME}" "${USER_NAME}"
        log "User '${USER_NAME}' added to '${GROUP_NAME}'."
    fi
}

# ----------------------------------------------------------------------------
# Step 4: Ensure sudoers drop-in exists (validated before install)
# ----------------------------------------------------------------------------
ensure_sudoers() {
    if [[ ! -d "${SUDOERS_DIR}" ]]; then
        log "Creating ${SUDOERS_DIR}..."
        install -d -m 0750 -o root -g root "${SUDOERS_DIR}"
    fi

    if [[ -f "${SUDOERS_FILE}" ]]; then
        log "Sudoers file '${SUDOERS_FILE}' already exists; leaving it unchanged."
        if ! grep -qxF "${SUDOERS_RULE}" "${SUDOERS_FILE}"; then
            warn "'${SUDOERS_FILE}' does not contain the expected rule: ${SUDOERS_RULE}"
        fi
    else
        log "Creating sudoers file '${SUDOERS_FILE}'..."
        TMP_FILE=$(mktemp)
        printf '%s\n' \
            "# Managed by setup_ansible_user.sh" \
            "# Members of ${GROUP_NAME} may run any command without a password." \
            "${SUDOERS_RULE}" > "${TMP_FILE}"

        # Validate syntax BEFORE installing; a broken sudoers file can lock out sudo.
        visudo -cf "${TMP_FILE}" >/dev/null \
            || die "Generated sudoers content failed validation; not installing."

        install -m 0440 -o root -g root "${TMP_FILE}" "${SUDOERS_FILE}"
        rm -f -- "${TMP_FILE}"
        TMP_FILE=""
        log "Sudoers file created."
    fi

    # Validate the complete sudo configuration, including all drop-ins.
    visudo -c >/dev/null || die "Overall sudoers configuration is invalid! Fix immediately."
}

# ----------------------------------------------------------------------------
# Step 5: Verify user creation and permissions
# ----------------------------------------------------------------------------
verify_setup() {
    log "Verifying configuration..."
    local failures=0 perms

    if id -u "${USER_NAME}" &>/dev/null; then
        log "  [OK]   User exists: $(id "${USER_NAME}")"
    else
        warn "  [FAIL] User '${USER_NAME}' does not exist."
        (( failures++ )) || true
    fi

    if user_in_group "${USER_NAME}" "${GROUP_NAME}"; then
        log "  [OK]   '${USER_NAME}' is a member of '${GROUP_NAME}'."
    else
        warn "  [FAIL] '${USER_NAME}' is not a member of '${GROUP_NAME}'."
        (( failures++ )) || true
    fi

    if [[ -f "${SUDOERS_FILE}" ]]; then
        perms=$(stat -c '%a %U:%G' "${SUDOERS_FILE}")
        if [[ "${perms}" == "440 root:root" ]]; then
            log "  [OK]   ${SUDOERS_FILE} permissions: ${perms}"
        else
            warn "  [FAIL] ${SUDOERS_FILE} has permissions '${perms}' (expected '440 root:root')."
            (( failures++ )) || true
        fi
    else
        warn "  [FAIL] ${SUDOERS_FILE} is missing."
        (( failures++ )) || true
    fi

    if sudo -l -U "${USER_NAME}" 2>/dev/null | grep -q 'NOPASSWD: ALL'; then
        log "  [OK]   '${USER_NAME}' has passwordless sudo."
    else
        warn "  [FAIL] '${USER_NAME}' does not have passwordless sudo."
        warn "         Ensure /etc/sudoers contains '#includedir ${SUDOERS_DIR}' or '@includedir ${SUDOERS_DIR}'."
        (( failures++ )) || true
    fi

    (( failures == 0 )) || die "Verification failed with ${failures} error(s)."
    log "Verification passed."
}

# ----------------------------------------------------------------------------
# Step 6: Ensure SSH authorized_keys exists with the provided key
# ----------------------------------------------------------------------------
ensure_authorized_keys() {
    local home_dir primary_group ssh_dir auth_keys

    home_dir=$(getent passwd "${USER_NAME}" | cut -d: -f6)
    [[ -n "${home_dir}" && -d "${home_dir}" ]] \
        || die "Home directory for '${USER_NAME}' not found (got: '${home_dir}')."

    primary_group=$(id -gn "${USER_NAME}")
    ssh_dir="${home_dir}/.ssh"
    auth_keys="${ssh_dir}/authorized_keys"

    # Create .ssh or enforce correct ownership/permissions (sshd StrictModes).
    install -d -m 0700 -o "${USER_NAME}" -g "${primary_group}" "${ssh_dir}"

    if [[ -f "${auth_keys}" ]]; then
        log "'${auth_keys}' already exists."
        if grep -qxF "${SSH_PUBKEY}" "${auth_keys}"; then
            log "Provided public key is already present."
        else
            warn "Provided public key not found; appending it."
            printf '%s\n' "${SSH_PUBKEY}" >> "${auth_keys}"
        fi
    else
        log "Creating '${auth_keys}'..."
        TMP_FILE=$(mktemp)
        printf '%s\n' "${SSH_PUBKEY}" > "${TMP_FILE}"
        install -m 0600 -o "${USER_NAME}" -g "${primary_group}" "${TMP_FILE}" "${auth_keys}"
        rm -f -- "${TMP_FILE}"
        TMP_FILE=""
        log "'${auth_keys}' created."
    fi

    chown "${USER_NAME}:${primary_group}" "${auth_keys}"
    chmod 0600 "${auth_keys}"

    # Restore SELinux contexts where applicable (RHEL/CentOS/Fedora).
    if command -v restorecon &>/dev/null; then
        restorecon -R "${ssh_dir}" || warn "restorecon failed on ${ssh_dir}."
    fi

    log "  [OK]   $(stat -c '%A %U:%G %n' "${ssh_dir}")"
    log "  [OK]   $(stat -c '%A %U:%G %n' "${auth_keys}")"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
    require_root
    require_commands id getent useradd groupadd usermod visudo sudo install stat mktemp grep cut

    ensure_user
    ensure_group
    ensure_membership
    ensure_sudoers
    verify_setup
    ensure_authorized_keys

    log "Setup of '${USER_NAME}' completed successfully."
}

main "$@"