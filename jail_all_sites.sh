#!/bin/bash
set -euo pipefail
set -x  # debug

##############################
# CloudPanel Site Jailer
##############################

# Default configuration
DB_PATH="/home/clp/htdocs/app/data/db.sq3"
JAIL_ROOT="/home/jail"
LOGFILE="/var/log/jail_all_sites.log"

# Colors for output
RED='\033[0;31m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; BLUE='\033[0;34m'
NC='\033[0m' # No Color

VERBOSE=false
SKIP_CONFIRM=false

#################################
# Utility functions
#################################

log() {
    local level=$1 message=$2 color=$NC
    case $level in
        ERROR)   color=$RED ;;
        SUCCESS) color=$GREEN ;;
        WARNING) color=$YELLOW ;;
        INFO)    color=$BLUE ;;
    esac
    echo -e "${color}[$(date +'%F %T')] $message${NC}" | tee -a "$LOGFILE"
}

show_help() {
    cat <<EOF
${BLUE}CloudPanel Site Jailer${NC}

Usage: $0 [options]

Options:
  -h, --help           Show help
  -d, --db-path PATH   Custom CloudPanel DB path
  -j, --jail-root PATH Custom jail root
  -l, --log-file PATH  Custom log file
  -v, --verbose        Enable verbose
  -y, --yes            Skip confirmation

Example:
  $0 --db-path /path/db.sq3 --jail-root /custom/jail
EOF
    exit 0
}

#################################
# Argument parsing
#################################

mkdir -p "$(dirname "$LOGFILE")"
touch "$LOGFILE"
trap 'log ERROR "Interrupted"; exit 1' INT TERM

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)   show_help ;;
        -d|--db-path)
            [[ -z "${2-:-}" ]] && { log ERROR "--db-path needs an argument"; exit 1; }
            DB_PATH="$2"; shift 2 ;;
        -j|--jail-root)
            [[ -z "${2-:-}" ]] && { log ERROR "--jail-root needs an argument"; exit 1; }
            JAIL_ROOT="$2"; shift 2 ;;
        -l|--log-file)
            [[ -z "${2-:-}" ]] && { log ERROR "--log-file needs an argument"; exit 1; }
            LOGFILE="$2"; shift 2 ;;
        -v|--verbose) VERBOSE=true; shift ;;
        -y|--yes)     SKIP_CONFIRM=true; shift ;;
        *)            log ERROR "Unknown option $1"; show_help ;;
    esac
done

#################################
# Core functions
#################################

check_root() {
    [ "$(id -u)" -ne 0 ] && { log ERROR "Must run as root"; exit 1; }
}

validate_config() {
    local d; d="$(dirname "$DB_PATH")"
    [ ! -d "$d" ] && { log ERROR "CloudPanel dir not found: $d"; exit 1; }
    [ ! -f "$DB_PATH" ] && { log ERROR "DB not found at: $DB_PATH"; exit 1; }
}

install_dependencies() {
    for cmd in sqlite3 jk_init jk_jailuser; do
        if ! command -v "$cmd" &> /dev/null; then
            [ "$cmd" = sqlite3 ] && { log ERROR "sqlite3 missing"; exit 1; }
            log WARNING "Installing jailkit..."
            DEBIAN_FRONTEND=noninteractive apt-get update \
              && apt-get install -y --no-install-recommends jailkit
            break
        fi
    done
}

initialize_jail() {
    echo "DEBUG: Entering initialize_jail" >&2
    if [ ! -d "$JAIL_ROOT" ]; then
        log INFO "Initializing global jail at $JAIL_ROOT"
        mkdir -p "$JAIL_ROOT"
        chown root:root "$JAIL_ROOT"; chmod 755 "$JAIL_ROOT"
        echo "DEBUG: Set permissions on $JAIL_ROOT to 755" >&2
        
        if ! jk_init -v "$JAIL_ROOT" basicshell netutils ssh sftp scp editors; then
            echo "DEBUG: jk_init failed for global jail" >&2
            log WARNING "jk_init failed for global jail, creating manually"
        fi
        
        mkdir -p "$JAIL_ROOT/usr/sbin" "$JAIL_ROOT/etc"
        cp /usr/sbin/jk_lsh   "$JAIL_ROOT/usr/sbin/"; chmod 755 "$JAIL_ROOT/usr/sbin/jk_lsh"
        cp /usr/sbin/jk_chrootsh "$JAIL_ROOT/usr/sbin/"; chmod 755 "$JAIL_ROOT/usr/sbin/jk_chrootsh"
        grep -E '^(root|nobody):' /etc/passwd >"$JAIL_ROOT/etc/passwd"
        grep -E '^(root|nobody):' /etc/group  >"$JAIL_ROOT/etc/group"
        chown -R root:root "$JAIL_ROOT"; chmod -R 755 "$JAIL_ROOT"
    fi
    echo "DEBUG: Exiting initialize_jail" >&2
}

get_site_users() {
    sqlite3 "$DB_PATH" \
      "SELECT DISTINCT user FROM site WHERE user!='' AND user IS NOT NULL;"
}

create_user() {
    local u=$1
    if ! id "$u" &> /dev/null; then
        log INFO "Creating user '$u'..."
        useradd -m -s /usr/sbin/jk_chrootsh "$u"
        log SUCCESS "User '$u' created"
    fi
}

unjail_user() {
    local u=$1 jhome="$JAIL_ROOT/$u/home/$u"
    sed -i "\#^/home/$u[[:space:]]\+$jhome#d" /etc/fstab 2>/dev/null || :
    mountpoint -q "$jhome" && umount "$jhome"
    usermod -s /bin/bash "$u"
    log INFO "Unjailed '$u'"
}

jail_user() {
    local u=$1 user_jail="$JAIL_ROOT/$u" real_home="/home/$u" jhome="$user_jail/home/$u"
    echo "DEBUG: Jailing user $u" >&2
    create_user "$u"
    unjail_user "$u"

    # (Re)init per‑user jail
    mkdir -p "$user_jail"
    chown root:root "$user_jail"; chmod 755 "$user_jail"
    echo "DEBUG: Set permissions on $user_jail to 755" >&2
    
    if ! jk_init -v "$user_jail" basicshell netutils ssh sftp scp editors; then
        echo "DEBUG: jk_init failed for $u" >&2
        log WARNING "jk_init failed for $u, creating manually"
    fi
    
    mkdir -p "$user_jail/usr/sbin" "$user_jail/etc" "$user_jail/bin" "$user_jail/lib" "$user_jail/lib64"
    cp /usr/sbin/jk_lsh   "$user_jail/usr/sbin/"; chmod 755 "$user_jail/usr/sbin/jk_lsh"
    cp /usr/sbin/jk_chrootsh "$user_jail/usr/sbin/"; chmod 755 "$user_jail/usr/sbin/jk_chrootsh"
    grep -E '^(root|nobody):' /etc/passwd >"$user_jail/etc/passwd"
    grep -E '^(root|nobody):' /etc/group  >"$user_jail/etc/group"
    chown -R root:root "$user_jail"; chmod -R 755 "$user_jail"

    # bind-mount real home
    if [ -d "$real_home" ]; then
        mkdir -p "$jhome"
        mountpoint -q "$jhome" || mount --bind "$real_home" "$jhome"
        chmod 755 "$user_jail/home" "$jhome"; chown "$u:$u" "$jhome"
        grep -qs "^$real_home[[:space:]]\+$jhome" /etc/fstab || \
          (echo "$real_home $jhome none bind 0 0" >>/etc/fstab)
        log INFO "Bound $real_home → $jhome"
    else
        log WARNING "Real home not found: $real_home"
    fi

    # ensure jailed passwd/group entries
    grep -q "^$u:" "$user_jail/etc/passwd" || grep "^$u:" /etc/passwd >>"$user_jail/etc/passwd"
    grep -q "^$u:" "$user_jail/etc/group"  || grep "^$u:" /etc/group  >>"$user_jail/etc/group"

    # set shell & jail
    usermod -s /usr/sbin/jk_chrootsh "$u"
    if jk_jailuser -v -j "$user_jail" -s /usr/sbin/jk_chrootsh -n "$u"; then
        log SUCCESS "User '$u' jailed"
    else
        log ERROR   "Failed to jail '$u'"; usermod -s /bin/bash "$u"
    fi
}

show_summary() {
    log INFO "Config: DB=$DB_PATH, JAIL_ROOT=$JAIL_ROOT"
    echo
    local users; users=$(get_site_users)
    [ -z "$users" ] && { log WARNING "No users to jail"; return; }
    log INFO "Users:"; for u in $users; do log INFO " - $u"; done
    $SKIP_CONFIRM || { read -rp "Proceed? (y/N) " a; [[ $a =~ ^[Yy]$ ]] || { log INFO "Aborted"; exit 0; }; }
}

#################################
# Main
#################################
main() {
    echo "DEBUG: Starting main function" >&2
    check_root
    echo "DEBUG: After check_root" >&2
    
    validate_config
    echo "DEBUG: After validate_config" >&2
    
    install_dependencies
    echo "DEBUG: After install_dependencies" >&2
    
    initialize_jail
    echo "DEBUG: After initialize_jail" >&2
    
    show_summary
    echo "DEBUG: After show_summary" >&2
    
    for u in $(get_site_users); do 
        jail_user "$u"
        echo "DEBUG: After jailing user $u" >&2
    done
    
    log SUCCESS "All site users jailed."
    echo "DEBUG: Script completed successfully" >&2
}

main "$@"
