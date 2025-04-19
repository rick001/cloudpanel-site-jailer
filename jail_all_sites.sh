#!/bin/bash
set -euo pipefail
trap 'cleanup_on_exit' EXIT ERR

##############################
# CloudPanel Site Jailer
##############################

# Configuration
DB_PATH="${DB_PATH:-/home/clp/htdocs/app/data/db.sq3}"
JAIL_ROOT="${JAIL_ROOT:-/home/jail}"
LOGFILE="${LOGFILE:-/var/log/jail_all_sites.log}"
BASE_JAIL="${JAIL_ROOT}/_base"
JK_PROFILE="cloudpanel"

# Safety checks
VALID_USERNAME_RE='^[a-z_][a-z0-9_-]*$'
declare -a MOUNTED_PATHS=()
PERSISTENT_MOUNT=false

# Colors
[ -t 1 ] && COLOR=true || COLOR=false
RED=$($COLOR && echo -e '\033[0;31m')    GREEN=$($COLOR && echo -e '\033[0;32m')
YELLOW=$($COLOR && echo -e '\033[1;33m') BLUE=$($COLOR && echo -e '\033[0;34m')
NC=$($COLOR && echo -e '\033[0m')

# Runtime flags
VERBOSE=false FIX_MODE=false DIAGNOSE_MODE=false DIAGNOSE_USER=""

#################################
# Utility Functions
#################################

cleanup_on_exit() {
    local status=$?
    for path in "${MOUNTED_PATHS[@]}"; do
        [[ "$path" == PERSISTENT:* ]] && continue
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
        if $PERSISTENT_MOUNT; then
            MOUNTED_PATHS+=("PERSISTENT:$dst")
        else
            MOUNTED_PATHS+=("$dst")
        fi
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

    # Create essential directory structure for libraries
    mkdir -p "$BASE_JAIL/lib/x86_64-linux-gnu"
    
    # Copy critical shared libraries
    log INFO "Copying system libraries..."
    for lib in libc.so.6 ld-linux-x86-64.so.2; do
        lib_path="/lib/x86_64-linux-gnu/$lib"
        if [ -f "$lib_path" ]; then
            cp -pv "$lib_path" "$BASE_JAIL/lib/x86_64-linux-gnu/"
        else
            log ERROR "Critical library missing: $lib_path"
            return 1
        fi
    done

    # Configure valid shells
    log INFO "Configuring shell environment..."
    mkdir -p "$BASE_JAIL/etc"
    echo -e "/usr/sbin/jk_chrootsh\n/bin/bash\n/bin/sh" > "$BASE_JAIL/etc/shells"

    # Add jailkit control binaries
    jk_cp -v -k "$BASE_JAIL" /usr/sbin/jk_lsh /usr/sbin/jk_chrootsh

    # Create essential devices with safety checks
    log INFO "Creating device nodes..."
    mkdir -p "$BASE_JAIL/dev"
    declare -A devices=(
        ["null"]="c 1 3"
        ["zero"]="c 1 5"
        ["random"]="c 1 8"
        ["urandom"]="c 1 9"
    )
    for dev in "${!devices[@]}"; do
        if [ ! -e "$BASE_JAIL/dev/$dev" ]; then
            mknod -m 666 "$BASE_JAIL/dev/$dev" ${devices[$dev]}
        fi
    done

    # Verify base structure
    log INFO "Verifying base jail integrity..."
    local required_paths=(
        "/usr/sbin/jk_chrootsh"
        "/etc/shells"
        "/lib/x86_64-linux-gnu/libc.so.6"
    )
    for path in "${required_paths[@]}"; do
        if [ ! -e "$BASE_JAIL$path" ]; then
            log ERROR "Missing critical path: $BASE_JAIL$path"
            return 1
        fi
    done

    log SUCCESS "Base jail created with full dependencies"
    return 0
}

create_user_jail() {
    local u=$1
    local user_jail="${JAIL_ROOT}/${u}"
    local real_home="/home/${u}"
    local jail_home="${user_jail}${real_home}"

    if [ ! -d "$user_jail" ]; then
        log INFO "Cloning base jail for $u"
        cp -a "$BASE_JAIL" "$user_jail" || {
            log ERROR "Failed cloning base jail"; return 1
        }
    fi

    # Preserve base users and add jailed user
    mkdir -p "${user_jail}/etc"
    cp "${BASE_JAIL}/etc/passwd" "${user_jail}/etc/passwd"
    cp "${BASE_JAIL}/etc/group" "${user_jail}/etc/group"
    grep "^${u}:" /etc/passwd >> "${user_jail}/etc/passwd"
    grep "^${u}:" /etc/group >> "${user_jail}/etc/group"

    # Copy shell configuration
    cp "${BASE_JAIL}/etc/shells" "${user_jail}/etc/shells"

    # Home directory mount
    PERSISTENT_MOUNT=true
    safe_mount "$real_home" "$jail_home" || return 1
    PERSISTENT_MOUNT=false

    if ! grep -qE "^${real_home}[[:space:]]+${jail_home}[[:space:]]+" /etc/fstab; then
        echo "$real_home $jail_home none bind 0 0" >> /etc/fstab
        log INFO "Added fstab entry for $u"
    fi

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

    if mountpoint -q "$jail_home"; then
        umount "$jail_home" || { log ERROR "Unmount failed for $jail_home"; return 1; }
        log INFO "Unmounted $jail_home"
    fi

    sed -i "\|${jail_home}|d" /etc/fstab

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
    [ -f "$DB_PATH" ] || { log ERROR "Database not found: $DB_PATH"; exit 1; }
    sqlite3 "$DB_PATH" \
        "SELECT DISTINCT user FROM site WHERE user!='' AND user IS NOT NULL;" |
    while read -r u; do
        validate_user "$u" && echo "$u"
    done
}

check_dependencies() {
    local required=("sqlite3" "jailkit")
    local missing=()
    for pkg in "${required[@]}"; do
        dpkg -l "$pkg" &>/dev/null || missing+=("$pkg")
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        log INFO "Installing missing packages..."
        apt-get update && apt-get install -y "${missing[@]}"
    fi
}

diagnose_user() {
    local u=$1
    validate_user "$u" || return 1
    
    echo "=== Diagnosis for $u ==="
    echo "Shell: $(getent passwd "$u" | cut -d: -f7)"
    echo "Jail Home: ${JAIL_ROOT}/${u}/home/${u}"
    echo "Mount Status: $(mountpoint -q "${JAIL_ROOT}/${u}/home/${u}" && echo "Mounted" || echo "Not Mounted")"
    echo "Fstab Entry: $(grep -E "^/home/${u}[[:space:]]+" /etc/fstab || echo "None")"
    echo "=== End Diagnosis ==="
}

main() {
    [ "$(id -u)" -eq 0 ] || { log ERROR "Must be run as root!"; exit 1; }
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

    while read -r u; do
        log INFO "Processing user: $u"
        create_user_jail "$u" || log WARNING "Failed to jail $u"
    done < <(get_site_users)

    log SUCCESS "Operation completed"
}

# Argument parsing
while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose) VERBOSE=true; set -x ;;
        --fix) FIX_MODE=true ;;
        --diagnose) DIAGNOSE_MODE=true; DIAGNOSE_USER=$2; shift ;;
        -*) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

mkdir -p "$(dirname "$LOGFILE")"
touch "$LOGFILE"
main