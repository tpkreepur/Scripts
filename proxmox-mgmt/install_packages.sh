#!/bin/sh
#
# install_packages.sh
#
# Installs the packages needed to provision and manage a host with Ansible:
#   - bash, sudo, shadow utilities  (required by setup_ansible_user.sh)
#   - openssh-server                (so Ansible can connect)
#   - python3                       (required by most Ansible modules)
# Then enables and starts the SSH service.
#
# Supported: Debian, Ubuntu, Rocky (and other RHEL-likes), Alpine.
# The OS is detected from /etc/os-release. Safe to run multiple times; only
# missing packages are installed. Must be run as root.
#
# Usage: sh install_packages.sh
#
# Run it with "sh", not "bash": Alpine has no bash until this script installs
# it. The POSIX block below installs bash if needed, then re-runs the script
# under bash.

# --- POSIX bootstrap (must stay sh-compatible) ------------------------------
if [ -z "${BASH_VERSION:-}" ]; then
    if ! command -v bash >/dev/null 2>&1; then
        if command -v apk >/dev/null 2>&1; then
            echo "[bootstrap] bash not found; installing with apk..."
            apk add --no-cache bash || { echo "[bootstrap] failed to install bash" >&2; exit 1; }
        else
            echo "[bootstrap] bash is required but not installed." >&2
            exit 1
        fi
    fi
    if [ ! -f "$0" ]; then
        echo "[bootstrap] Run this script from a file (sh /path/to/install_packages.sh), not stdin." >&2
        exit 1
    fi
    exec bash "$0" "$@"
fi

# --- Bash from here on ---------------------------------------------------------
set -Eeuo pipefail
IFS=$'\n\t'

readonly DEBIAN_PACKAGES=(sudo openssh-server python3)
readonly RHEL_PACKAGES=(sudo openssh-server python3 shadow-utils)
readonly ALPINE_PACKAGES=(bash shadow sudo openssh python3)

OS_FAMILY=""
OS_NAME=""

log()  { printf '[%s] [INFO]  %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] [WARN]  %s\n' "$(date '+%F %T')" "$*" >&2; }
die()  { printf '[%s] [ERROR] %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }

on_error() {
    local exit_code=$?
    printf '[%s] [ERROR] Command failed (exit %d) at line %d: %s\n' \
        "$(date '+%F %T')" "${exit_code}" "${BASH_LINENO[0]}" "${BASH_COMMAND}" >&2
    exit "${exit_code}"
}
trap on_error ERR

require_root() {
    [[ ${EUID} -eq 0 ]] || die "This script must be run as root."
}

# ----------------------------------------------------------------------------
# Detect OS family from /etc/os-release (ID first, then ID_LIKE)
# ----------------------------------------------------------------------------
detect_os() {
    [[ -r /etc/os-release ]] || die "/etc/os-release not found; cannot detect OS."

    local id like candidate
    local -a candidates
    id=$(. /etc/os-release && printf '%s' "${ID:-}")
    like=$(. /etc/os-release && printf '%s' "${ID_LIKE:-}")
    OS_NAME=$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-${ID:-unknown}}")

    IFS=' ' read -ra candidates <<< "${id} ${like}"
    for candidate in "${candidates[@]}"; do
        case ${candidate} in
            debian|ubuntu)                          OS_FAMILY=debian; break ;;
            rhel|rocky|almalinux|centos|fedora)     OS_FAMILY=rhel;   break ;;
            alpine)                                 OS_FAMILY=alpine; break ;;
        esac
    done

    [[ -n ${OS_FAMILY} ]] || die "Unsupported OS: ${OS_NAME} (ID=${id}, ID_LIKE=${like})"
    log "Detected ${OS_NAME} (family: ${OS_FAMILY})"
}

# ----------------------------------------------------------------------------
# Print each package from the arguments that is not yet installed
# ----------------------------------------------------------------------------
missing_packages() {
    local pkg
    for pkg in "$@"; do
        case ${OS_FAMILY} in
            debian)
                dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null \
                    | grep -q 'install ok installed' || printf '%s\n' "${pkg}" ;;
            rhel)
                rpm -q --quiet --whatprovides "${pkg}" || printf '%s\n' "${pkg}" ;;
            alpine)
                apk info -e "${pkg}" >/dev/null 2>&1 || printf '%s\n' "${pkg}" ;;
        esac
    done
}

# ----------------------------------------------------------------------------
# Install the given packages with the native package manager
# ----------------------------------------------------------------------------
install_packages() {
    log "Installing: $*"
    case ${OS_FAMILY} in
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get -o DPkg::Lock::Timeout=300 update -qq
            apt-get -o DPkg::Lock::Timeout=300 install -y -qq --no-install-recommends "$@"
            ;;
        rhel)
            local pm=dnf
            command -v dnf &>/dev/null || pm=yum
            "${pm}" install -y -q "$@"
            ;;
        alpine)
            apk add --no-cache "$@"
            ;;
    esac
}

# ----------------------------------------------------------------------------
# Enable and start SSH (systemd or OpenRC)
# ----------------------------------------------------------------------------
enable_ssh() {
    if [[ -d /run/systemd/system ]] && command -v systemctl &>/dev/null; then
        if [[ ${OS_FAMILY} == debian ]] && systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
            # Newer Ubuntu releases use socket activation; don't fight it.
            systemctl is-active --quiet ssh.socket || systemctl start ssh.socket
            log "SSH is socket-activated (ssh.socket enabled and active)."
            return 0
        fi

        local unit=sshd
        [[ ${OS_FAMILY} == debian ]] && unit=ssh
        systemctl enable --now "${unit}.service" >/dev/null 2>&1 \
            || die "Failed to enable/start ${unit}.service"
        log "SSH service '${unit}' enabled and running."

    elif command -v rc-update &>/dev/null; then
        if ! rc-update show default 2>/dev/null | grep -qw sshd; then
            rc-update add sshd default >/dev/null
        fi
        # The OpenRC sshd service generates host keys on first start.
        rc-service sshd status >/dev/null 2>&1 || rc-service sshd start
        log "SSH service 'sshd' enabled (OpenRC) and running."

    else
        warn "No supported init system found; enable and start sshd manually."
    fi
}

# ----------------------------------------------------------------------------
# Verify required commands are now available
# ----------------------------------------------------------------------------
verify() {
    local cmd failures=0
    for cmd in bash sudo visudo useradd groupadd usermod python3 sshd; do
        if command -v "${cmd}" &>/dev/null; then
            log "  [OK]   ${cmd} -> $(command -v "${cmd}")"
        else
            warn "  [FAIL] ${cmd} not found"
            (( failures++ )) || true
        fi
    done
    (( failures == 0 )) || die "Verification failed: ${failures} command(s) missing."
    log "All required packages are installed."
}

main() {
    require_root
    detect_os

    local -a wanted missing
    case ${OS_FAMILY} in
        debian) wanted=("${DEBIAN_PACKAGES[@]}") ;;
        rhel)   wanted=("${RHEL_PACKAGES[@]}") ;;
        alpine) wanted=("${ALPINE_PACKAGES[@]}") ;;
    esac

    mapfile -t missing < <(missing_packages "${wanted[@]}")

    if (( ${#missing[@]} == 0 )); then
        log "All packages already installed: ${wanted[*]}"
    else
        install_packages "${missing[@]}"
    fi

    enable_ssh
    verify
}

main "$@"