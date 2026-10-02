#!/bin/sh
#
# install_packages.sh
#
# Installs the packages needed to provision and manage a host with Ansible:
#   - bash, sudo, shadow utilities  (required by setup_ansible_user.sh)
#   - openssh-server                (so Ansible can connect)
#   - python3                       (required by most Ansible modules)
#   - lldpd                         (LLDP neighbor advertisement)
# Then writes /etc/lldpd.d/lldpd.conf using NAME from /etc/os-release, and
# enables and starts the SSH and lldpd services.
#
# Supported: Debian, Ubuntu, Rocky (and other RHEL-likes), Alpine.
# On RHEL-likes other than Fedora, lldpd comes from EPEL, which is enabled
# automatically via the epel-release package.
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

readonly DEBIAN_PACKAGES=(sudo openssh-server python3 lldpd)
readonly RHEL_PACKAGES=(sudo openssh-server python3 shadow-utils lldpd)
readonly ALPINE_PACKAGES=(bash shadow sudo openssh python3 lldpd)

readonly LLDPD_CONF_DIR="/etc/lldpd.d"
readonly LLDPD_CONF="${LLDPD_CONF_DIR}/lldpd.conf"

OS_FAMILY=""
OS_ID=""
OS_NAME=""          # PRETTY_NAME, used in log messages
OS_SHORT_NAME=""    # NAME, used in the LLDP system description
LLDPD_CONF_CHANGED=0
TMP_FILE=""

log()  { printf '[%s] [INFO]  %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] [WARN]  %s\n' "$(date '+%F %T')" "$*" >&2; }
die()  { printf '[%s] [ERROR] %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }

# Join arguments with spaces (IFS is newline/tab, so "${arr[*]}" would not).
join() { local IFS=' '; printf '%s' "$*"; }

cleanup() {
    if [[ -n ${TMP_FILE} && -f ${TMP_FILE} ]]; then
        rm -f -- "${TMP_FILE}"
    fi
}
trap cleanup EXIT

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
    OS_SHORT_NAME=$(. /etc/os-release && printf '%s' "${NAME:-${ID:-Linux}}")
    OS_ID=${id}

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
    log "Installing: $(join "$@")"
    case ${OS_FAMILY} in
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get -o DPkg::Lock::Timeout=300 update -qq
            apt-get -o DPkg::Lock::Timeout=300 install -y -qq --no-install-recommends "$@"
            ;;
        rhel)
            local pm=dnf pkg needs_epel=0
            command -v dnf &>/dev/null || pm=yum

            # lldpd is not in the base repos of EL distributions; it comes from
            # EPEL. Fedora ships it in its main repositories.
            for pkg in "$@"; do
                if [[ ${pkg} == lldpd ]]; then
                    needs_epel=1
                fi
            done
            if (( needs_epel )) && [[ ${OS_ID} != fedora ]] && ! rpm -q --quiet epel-release; then
                log "Enabling EPEL repository (required for lldpd)..."
                "${pm}" install -y -q epel-release
            fi

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
# Write /etc/lldpd.d/lldpd.conf; only replaced when the content differs
# ----------------------------------------------------------------------------
configure_lldpd() {
    # Escape any double quotes in NAME so the lldpcli string stays valid.
    local escaped_name=${OS_SHORT_NAME//\"/\\\"}
    local desired
    desired=$(printf '%s\n' \
        "configure system description \"LXC ${escaped_name} Server\"" \
        "configure lldp tx-interval 30" \
        "configure lldp portidsubtype macaddress")

    install -d -m 0755 -o root -g root "${LLDPD_CONF_DIR}"

    if [[ -f ${LLDPD_CONF} && "$(< "${LLDPD_CONF}")" == "${desired}" ]]; then
        log "${LLDPD_CONF} is already up to date."
        return 0
    fi

    # Write to a temp file, then install it, so the config is never half-written.
    TMP_FILE=$(mktemp)
    printf '%s\n' "${desired}" > "${TMP_FILE}"
    install -m 0644 -o root -g root "${TMP_FILE}" "${LLDPD_CONF}"
    rm -f -- "${TMP_FILE}"
    TMP_FILE=""

    LLDPD_CONF_CHANGED=1
    log "Wrote ${LLDPD_CONF} (system description: \"LXC ${OS_SHORT_NAME} Server\")."
}

# ----------------------------------------------------------------------------
# Enable a service at boot and make sure it is running (systemd or OpenRC).
# If the second argument is 1, restart it so a changed config takes effect.
# ----------------------------------------------------------------------------
enable_service() {
    local svc=$1 restart=${2:-0}

    if [[ -d /run/systemd/system ]] && command -v systemctl &>/dev/null; then
        systemctl enable --quiet "${svc}.service"
        if (( restart )); then
            systemctl restart "${svc}.service"
        else
            systemctl is-active --quiet "${svc}.service" || systemctl start "${svc}.service"
        fi

    elif command -v rc-update &>/dev/null; then
        if ! rc-update show default 2>/dev/null | grep -qw "${svc}"; then
            rc-update add "${svc}" default >/dev/null
        fi
        if (( restart )); then
            rc-service "${svc}" restart
        else
            rc-service "${svc}" status >/dev/null 2>&1 || rc-service "${svc}" start
        fi

    else
        warn "No supported init system found; enable and start ${svc} manually."
        return 0
    fi

    log "Service '${svc}' enabled and running."
}

# ----------------------------------------------------------------------------
# Check that lldpd picked up the configured system description.
# Warning only: the daemon can take a moment to become ready.
# ----------------------------------------------------------------------------
verify_lldpd() {
    local expected="LXC ${OS_SHORT_NAME} Server" attempt
    for attempt in 1 2 3 4 5; do
        if lldpcli show chassis 2>/dev/null | grep -qF -- "${expected}"; then
            log "  [OK]   lldpd is advertising: ${expected}"
            return 0
        fi
        sleep 1
    done
    warn "  [WARN] lldpd is not yet reporting '${expected}'. Check with: lldpcli show chassis"
}

# ----------------------------------------------------------------------------
# Verify required commands are now available
# ----------------------------------------------------------------------------
verify() {
    local cmd failures=0
    for cmd in bash sudo visudo useradd groupadd usermod python3 sshd lldpd lldpcli; do
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
        log "All packages already installed: $(join "${wanted[@]}")"
    else
        install_packages "${missing[@]}"
    fi

    configure_lldpd
    enable_ssh
    enable_service lldpd "${LLDPD_CONF_CHANGED}"
    verify
    verify_lldpd
}

main "$@"