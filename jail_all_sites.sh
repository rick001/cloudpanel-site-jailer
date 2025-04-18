#!/bin/bash
set -euo pipefail  # Strict error handling
trap 'cleanup_on_exit' EXIT ERR

##############################
# CloudPanel Site Jailer
##############################

# Configuration
DB_PATH="${DB_PATH:-/home/clp/htdocs/app/data/db.sq3}"
JAIL_ROOT="${JAIL_ROOT:-/home/jail}"
LOGFILE="${LOGFILE:-/var/log/jail_all_sites.log}"
BASE_JAIL="${JAIL_ROOT}/_base"  # Shared base jail
JK_PROFILE="cloudpanel"

# Safety checks
VALID_USERNAME_RE='^[a-z_][a-z0-9_-]*$'
declare -a MOUNTED_PATHS=()

# Colors (only when running interactively)
[ -t 1 ] && COLOR=true || COLOR=false
RED=$($COLOR && echo -e '\033[0;31m')    GREEN=$($COLOR && echo -e '\033[0;32m')
YELLOW=$($COLOR && echo -e '\033[1;33m') BLUE=$($COLOR && echo -e '\033[0;34m')
NC=$($COLOR && echo -e '\033[0m')

# Runtime flags
VERBOSE=false SKIP_CONFIRM=false FIX_MODE=false DIAGNOSE_MODE=false DIAGNOSE_USER=""

#################################
# Utility Functions
#################################

cleanup_on_exit() {
    local status=$?
    for path in "${MOUNTED_PATHS[@]}"; do
        if mountpoint -q "$path"; then
            umount "$path" && log INFO "Unmounted $path" || :
        fi
    done
    exit $status
}

log() {
    local level=$1 message=$2
    local color=$NC timestamp="[$(date +'%F %T')]"
    
    case $level in
        ERROR)   color=$RED ;;
        SUCCESS) color=$GREEN ;;
        WARNING) color=$YELLOW ;;
        INFO)    color=$BLUE ;;
    esac

    $COLOR && echo -e "${color}${timestamp} ${message}${NC}" || echo "${timestamp} [${level}] ${message}"
    echo "${timestamp} [${level}] ${message}" >> "$LOGFILE"
}

validate_user() {
    local u=$1
    [[ "$u" =~ $VALID_USERNAME_RE ]] || {
        log ERROR "Invalid username: $u"; return 1
    }
    getent passwd "$u" >/dev/null || {
        log ERROR "User does not exist: $u"; return 1
    }
}

safe_mount() {
    local src=$1 dst=$2
    mkdir -p "$dst"
    if mountpoint -q "$dst"; then
        log WARNING "Already mounted: $dst"
        return 0
    fi
    if mount --bind "$src" "$dst"; then
        MOUNTED_PATHS+=("$dst")
        log SUCCESS "Mounted $src → $dst"
        return 0
    fi
    log ERROR "Failed mounting $src → $dst"
    return 1
}

#################################
# Core Jail Functions
#################################

init_base_jail() {
    [ -d "$BASE_JAIL" ] && return 0
    
    log INFO "Creating base jail..."
    mkdir -p "$BASE_JAIL"
    chown root:root "$BASE_JAIL"
    chmod 755 "$BASE_JAIL"

    # Initialize with jailkit
    if ! jk_init -v "$BASE_JAIL" basicshell netutils ssh sftp scp editors; then
        log ERROR "Base jail initialization failed"
        return 1
    fi

    # Add custom binaries
    jk_cp -v -k "$BASE_JAIL" /usr/sbin/jk_lsh /usr/sbin/jk_chrootsh

    # Create essential devices
    mkdir -p "$BASE_JAIL/dev"
    mknod -m 666 "$BASE_JAIL/dev/null" c 1 3
    mknod -m 666 "$BASE_JAIL/dev/zero" c 1 5

    log SUCCESS "Base jail created"
}

create_user_jail() {
    local u=$1
    local user_jail="${JAIL_ROOT}/${u}"
    local real_home="/home/${u}"
    local jail_home="${user_jail}${real_home}"

    # Clone from base jail
    if [ ! -d "$user_jail" ]; then
        log INFO "Cloning base jail for $u"
        cp -a "$BASE_JAIL" "$user_jail" || {
            log ERROR "Failed cloning base jail"; return 1
        }
    fi

    # Configure user environment
    mkdir -p "${user_jail}/etc"
    grep "^${u}:" /etc/passwd >> "${user_jail}/etc/passwd"
    grep "^${u}:" /etc/group >> "${user_jail}/etc/group"

    # Setup home directory binding
    safe_mount "$real_home" "$jail_home" || return 1

    # Persistent mount
    if ! grep -qF "$real_home $jail_home" /etc/fstab; then
        echo "$real_home $jail_home none bind 0 0" >> /etc/fstab
        log INFO "Added fstab entry for $u"
    fi

    # Set restricted shell
    if usermod -s /usr/sbin/jk_chrootsh "$u"; then
        log SUCCESS "Configured jail for $u"
        return 0
    fi
    
    log ERROR "Failed to jail user $u"
    return 1
}

unjail_user() {
    local u=$1
    local user_jail="${JAIL_ROOT}/${u}"
    local jail_home="${user_jail}/home/${u}"

    # Remove mounts
    if mountpoint -q "$jail_home"; then
        umount "$jail_home" && log INFO "Unmounted $jail_home"
    fi

    # Remove fstab entry
    sed -i "\|${jail_home}|d" /etc/fstab

    # Restore shell
    if usermod -s /bin/bash "$u"; then
        log SUCCESS "Restored $u to normal shell"
        return 0
    fi
    
    log ERROR "Failed to unjail $u"
    return 1
}

#################################
# Main Workflow
#################################

get_site_users() {
    sqlite3 "$DB_PATH" \
        "SELECT DISTINCT user FROM site WHERE user!='' AND user IS NOT NULL;" |
    while read -r u; do
        validate_user "$u" && echo "$u"
    done
}

check_dependencies() {
    local missing=()
    for cmd in sqlite3 jk_init jk_cp; do
        command -v "$cmd" >/dev/null || missing+=("$cmd")
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        log INFO "Installing jailkit..."
        apt-get update && apt-get install -y jailkit
    fi
}

diagnose_user() {
    local u=$1
    validate_user "$u" || return 1
    
    echo "=== Diagnosis for $u ==="
    echo "Shell: $(getent passwd "$u" | cut -d: -f7)"
    echo "Jail Home: ${JAIL_ROOT}/${u}/home/${u}"
    echo "Mount Status: $(mountpoint -q "${JAIL_ROOT}/${u}/home/${u}" && echo "Mounted" || echo "Not Mounted")"
    echo "=== End Diagnosis ==="
}

main() {
    check_dependencies
    init_base_jail || exit 1

    if $DIAGNOSE_MODE; then
        diagnose_user "$DIAGNOSE_USER"
        exit 0
    fi

    if $FIX_MODE; then
        while read -r u; do
            unjail_user "$u" || log WARNING "Failed to fix $u"
        done < <(get_site_users)
        exit 0
    fi

    # Main jailing process
    while read -r u; do
        log INFO "Processing user: $u"
        create_user_jail "$u" || log WARNING "Failed to jail $u"
    done < <(get_site_users)

    log SUCCESS "Operation completed"
}

# Argument parsing and execution
while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose) VERBOSE=true; set -x ;;
        -y|--yes) SKIP_CONFIRM=true ;;
        --fix) FIX_MODE=true ;;
        --diagnose) DIAGNOSE_MODE=true; DIAGNOSE_USER=$2; shift ;;
        -*) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

mkdir -p "$(dirname "$LOGFILE")"
touch "$LOGFILE"
main