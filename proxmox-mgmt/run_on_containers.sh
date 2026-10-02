#!/usr/bin/env bash
#
# run_on_containers.sh
#
# Runs setup_ansible_user.sh inside every running LXC container in the Proxmox
# cluster. The container's OS is taken from its tags (rocky, debian, ubuntu,
# alpine) and used to install prerequisites (bash, sudo, shadow) first.
#
# Run as root on any Proxmox node. Containers on other nodes are reached over
# the cluster's root SSH trust.
#
# Usage:
#   ./run_on_containers.sh [-n] [-t TAG]... [-s PATH]
#
#   -n, --dry-run       Show what would be done without changing anything
#   -t, --tag TAG       Only target containers with this OS tag (repeatable)
#   -s, --script PATH   Path to setup script (default: ./setup_ansible_user.sh)
#   -h, --help          Show this help

set -Eeuo pipefail
IFS=$'\n\t'

readonly SUPPORTED_TAGS=(rocky debian ubuntu alpine)
readonly LOCAL_NODE="$(hostname)"

SETUP_SCRIPT="./setup_ansible_user.sh"
DRY_RUN=0
TARGET_TAGS=()

OK=()
FAILED=()
SKIPPED=()

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
log()  { printf '[%s] [INFO]  %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] [WARN]  %s\n' "$(date '+%F %T')" "$*" >&2; }
die()  { printf '[%s] [ERROR] %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }

usage() {
    sed -n '/^# Usage:/,/^$/s/^# \{0,1\}//p' "$0"
    exit "${1:-0}"
}

parse_args() {
    while (( $# > 0 )); do
        case $1 in
            -n|--dry-run) DRY_RUN=1 ;;
            -t|--tag)     [[ -n ${2:-} ]] || die "--tag requires a value"; TARGET_TAGS+=("$2"); shift ;;
            -s|--script)  [[ -n ${2:-} ]] || die "--script requires a value"; SETUP_SCRIPT=$2; shift ;;
            -h|--help)    usage 0 ;;
            *)            warn "Unknown option: $1"; usage 1 ;;
        esac
        shift
    done
    (( ${#TARGET_TAGS[@]} > 0 )) || TARGET_TAGS=("${SUPPORTED_TAGS[@]}")
}

preflight() {
    [[ ${EUID} -eq 0 ]] || die "Run as root on a Proxmox node."
    command -v pvesh &>/dev/null || die "pvesh not found; is this a Proxmox node?"
    command -v jq &>/dev/null    || die "jq not found; install it with: apt install jq"
    [[ -r ${SETUP_SCRIPT} ]]     || die "Setup script not readable: ${SETUP_SCRIPT}"
}

# Run a command on a cluster node: directly if local, otherwise over SSH.
# stdin is passed through, so callers must redirect it explicitly.
on_node() {
    local node=$1
    shift
    if [[ ${node} == "${LOCAL_NODE}" ]]; then
        "$@"
    else
        ssh -o BatchMode=yes -o ConnectTimeout=10 "root@${node}" "$(printf '%q ' "$@")"
    fi
}

# Shell snippet that installs what setup_ansible_user.sh needs, per OS.
prereq_cmd() {
    case $1 in
        alpine)
            # Alpine ships with busybox only: needs bash, shadow (useradd etc.), sudo.
            echo 'command -v bash >/dev/null && command -v useradd >/dev/null && command -v sudo >/dev/null || apk add --no-cache bash shadow sudo' ;;
        debian|ubuntu)
            echo 'command -v sudo >/dev/null || { export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq sudo; }' ;;
        rocky)
            echo 'command -v sudo >/dev/null || dnf install -y -q sudo' ;;
    esac
}

# Return the first tag that is both a supported OS and a requested target.
detect_os() {
    local tags=$1 tag target
    local -a tag_list
    IFS=';' read -ra tag_list <<< "${tags}"
    for tag in "${tag_list[@]}"; do
        for target in "${TARGET_TAGS[@]}"; do
            if [[ ${tag} == "${target}" ]]; then
                printf '%s' "${tag}"
                return 0
            fi
        done
    done
    return 1
}

# ----------------------------------------------------------------------------
# Per-container work (returns non-zero on failure; does not exit)
# ----------------------------------------------------------------------------
process_ct() {
    local node=$1 vmid=$2 name=$3 os=$4

    log "[${vmid}] ${name} on ${node} (${os})"
    if (( DRY_RUN )); then
        log "[${vmid}] dry run: would install prerequisites and run ${SETUP_SCRIPT}"
        return 0
    fi
    # If bash is missing on container (i.e. Alpine), us POSIX sh to install and restart with bash.
    on_node "${node}" pct exec "${vmid}" -- sh -c 'cat > /tmp/install_packages.sh' < install_packages.sh \
        || { warn "[${vmid}] failed to copy install script"; return 1; }
    on_node "${node}" pct exec "${vmid}" -- sh /tmp/install_packages.sh </dev/null 2>&1 \
        | sed "s/^/[${vmid}] /" \
        || { warn "[${vmid}] package installation failed"; return 1; }

    if [[ ${os} == alpine ]]; then
        # Alpine's sshd (no PAM) rejects key logins for accounts with a locked
        # password ('!'), which is what useradd creates. Switch to '*' (no
        # password login possible, but not "locked").
        on_node "${node}" pct exec "${vmid}" -- \
            sh -c "if grep -q '^ansible:!' /etc/shadow; then usermod -p '*' ansible; fi" </dev/null \
            || { warn "[${vmid}] failed to unlock ansible account for SSH"; return 1; }
    fi
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
    parse_args "$@"
    preflight

    log "Querying cluster for LXC containers (targets: ${TARGET_TAGS[*]})..."

    local -a containers
    mapfile -t containers < <(
        pvesh get /cluster/resources --type vm --output-format json \
            | jq -r '.[]
                | select(.type == "lxc" and (.template // 0) != 1)
                | [.node, (.vmid | tostring), .status, (.name // "-"), (.tags // "")]
                | @tsv'
    )
    (( ${#containers[@]} > 0 )) || die "No LXC containers found in the cluster."

    local line node vmid status name tags os
    for line in "${containers[@]}"; do
        IFS=$'\t' read -r node vmid status name tags <<< "${line}"

        if ! os=$(detect_os "${tags}"); then
            SKIPPED+=("${vmid} (${name}): no matching OS tag [${tags:-none}]")
            continue
        fi
        if [[ ${status} != running ]]; then
            SKIPPED+=("${vmid} (${name}): ${status}")
            continue
        fi

        if process_ct "${node}" "${vmid}" "${name}" "${os}"; then
            OK+=("${vmid} (${name})")
        else
            FAILED+=("${vmid} (${name})")
        fi
    done

    echo
    log "Summary: ${#OK[@]} succeeded, ${#FAILED[@]} failed, ${#SKIPPED[@]} skipped"
    local item
    for item in "${OK[@]}";      do log  "  OK      ${item}"; done
    for item in "${FAILED[@]}";  do warn "  FAILED  ${item}"; done
    for item in "${SKIPPED[@]}"; do log  "  SKIPPED ${item}"; done

    (( ${#FAILED[@]} == 0 ))
}

main "$@"