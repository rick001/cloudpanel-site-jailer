#!/bin/bash
set -euo pipefail

##############################
# CloudPanel Site Jailer
##############################

# Default configuration
DB_PATH="/home/clp/htdocs/app/data/db.sq3"
JAIL_ROOT="/home/jail"
LOGFILE="/var/log/jail_all_sites.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

VERBOSE=false
SKIP_CONFIRM=false

#################################
# Utility functions
#################################

# Logging with timestamp and color
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

# Display help text
show_help() {
    cat <<EOF
${BLUE}CloudPanel Site Jailer${NC}

A utility to jail CloudPanel site users in chroot environments.

Usage: $0 [options]

Options:
  -h, --help             Show this help message
  -d, --db-path PATH     Specify custom CloudPanel database path
  -j, --jail-root PATH   Specify custom jail root directory
  -l, --log-file PATH    Specify custom log file path
  -v, --verbose          Enable verbose output
  -y, --yes              Skip confirmation prompts

Example:
  $0 --db-path /custom/path/db.sq3 --jail-root /custom/jail
EOF
    exit 0
}

#################################
# Argument parsing
#################################

# Ensure log directory exists before any logging
mkdir -p "$(dirname "$LOGFILE")"
touch "$LOGFILE"

# Trap interrupts for clean exit
trap 'log ERROR "Interrupted"; exit 1' INT TERM

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)    show_help ;;
        -d|--db-path)
            [[ -z "${2-:-}" ]] && { log ERROR "--db-path requires a non-empty argument"; exit 1; }
            DB_PATH="$2"; shift 2 ;;
        -j|--jail-root)
            [[ -z "${2-:-}" ]] && { log ERROR "--jail-root requires a non-empty argument"; exit 1; }
            JAIL_ROOT="$2"; shift 2 ;;
        -l|--log-file)
            [[ -z "${2-:-}" ]] && { log ERROR "--log-file requires a non-empty argument"; exit 1; }
            LOGFILE="$2"; shift 2 ;;
        -v|--verbose)  VERBOSE=true; shift ;;
        -y|--yes)      SKIP_CONFIRM=true; shift ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            show_help
            ;;
    esac
done

#################################
# Checks and setup
#################################

check_root() {
    [ "$(id -u)" -ne 0 ] && { log ERROR "This script must be run as root"; exit 1; }
}

validate_config() {
    local db_dir
    db_dir="$(dirname "$DB_PATH")"
    [ ! -d "$db_dir" ] && { log ERROR "CloudPanel directory not found: $db_dir"; exit 1; }
    [ ! -f "$DB_PATH" ] && { log ERROR "CloudPanel DB not found at: $DB_PATH"; exit 1; }
}

install_dependencies() {
    for cmd in sqlite3 jk_init jk_jailuser; do
        if ! command -v "$cmd" &> /dev/null; then
            [ "$cmd" = "sqlite3" ] && { log ERROR "sqlite3 required but missing"; exit 1; }
            log WARNING "Installing jailkit..."
            DEBIAN_FRONTEND=noninteractive apt-get update \
              && apt-get install -y --no-install-recommends jailkit
            break
        fi
    done
}

initialize_jail() {
    if [ ! -d "$JAIL_ROOT" ]; then
        log INFO "Initializing JailKit at $JAIL_ROOT"
        mkdir -p "$JAIL_ROOT"
        jk_init -v "$JAIL_ROOT" basicshell netutils ssh sftp scp editors
        mkdir -p "$JAIL_ROOT/usr/sbin" "$JAIL_ROOT/etc"
        cp /usr/sbin/jk_lsh "$JAIL_ROOT/usr/sbin/"; chmod 755 "$JAIL_ROOT/usr/sbin/jk_lsh"
        grep -E '^(root|nobody):' /etc/passwd >"$JAIL_ROOT/etc/passwd"
        grep -E '^(root|nobody):' /etc/group  >"$JAIL_ROOT/etc/group"
        chown -R root:root "$JAIL_ROOT"; chmod 755 "$JAIL_ROOT"
    fi
}

get_site_users() {
    sqlite3 "$DB_PATH" "SELECT DISTINCT user FROM site WHERE user!='' AND user IS NOT NULL;"
}

create_user() {
    local u=$1
    if ! id "$u" &>/dev/null; then
        log INFO "Creating system user '$u'..."
        useradd -m -s /usr/sbin/jk_lsh "$u"
        log SUCCESS "User '$u' created"
    fi
}

jail_user() {
    local u=$1
    create_user "$u"
    local user_jail="$JAIL_ROOT/$u"
    # init per-user jail
    if [ ! -d "$user_jail" ]; then
        log INFO "Setting up jail for '$u'…"
        mkdir -p "$user_jail"
        jk_init -v "$user_jail" basicshell netutils ssh sftp scp editors
        mkdir -p "$user_jail/usr/sbin" "$user_jail/etc"
        cp /usr/sbin/jk_lsh "$user_jail/usr/sbin/"; chmod 755 "$user_jail/usr/sbin/jk_lsh"
        grep -E '^(root|nobody):' /etc/passwd >"$user_jail/etc/passwd"
        grep -E '^(root|nobody):' /etc/group  >"$user_jail/etc/group"
        chown -R root:root "$user_jail"; chmod 755 "$user_jail"
    fi

    # bind-mount real home
    local real_home="/home/$u"; local jhome="$user_jail/home/$u"
    if [ -d "$real_home" ]; then
        mkdir -p "$jhome"
        if mountpoint -q "$jhome"; then
            log INFO " → $jhome already mounted"
        else
            mount --bind "$real_home" "$jhome"
            log INFO " → bound $real_home → $jhome"
        fi
        # persist in fstab
        if ! grep -qs "^$real_home[[:space:]]\+$jhome" /etc/fstab; then
            echo "$real_home $jhome none bind 0 0" >> /etc/fstab
            log INFO " → added fstab entry for bind-mount"
        fi
    else
        log WARNING " → real home not found: $real_home (user will land in /)"
    fi

    # ensure passwd/group entries
    if ! grep -q "^$u:" "$user_jail/etc/passwd"; then
        grep "^$u:" /etc/passwd >>"$user_jail/etc/passwd"
        log INFO " → added $u to jail passwd"
    fi
    if ! grep -q "^$u:" "$user_jail/etc/group"; then
        grep "^$u:" /etc/group  >>"$user_jail/etc/group"
        log INFO " → added $u to jail group"
    fi

    # perform the jail
    if jk_jailuser -v -j "$user_jail" -s /usr/sbin/jk_lsh -n "$u"; then
        log SUCCESS "User '$u' jailed (home via bind-mount)"
    else
        log ERROR   "Failed to jail '$u'"
    fi
}

show_summary() {
    log INFO "Configuration: DB=$DB_PATH  JAIL_ROOT=$JAIL_ROOT  LOGFILE=$LOGFILE"
    echo
    local users; users=$(get_site_users)
    if [ -z "$users" ]; then
        log WARNING "No users found in DB."
    else
        log INFO "Users to jail:"
        for u in $users; do log INFO " - $u"; done
    fi
    if ! $SKIP_CONFIRM && [ -n "$users" ]; then
        read -rp "Proceed? (y/N) " ans; echo
        [[ $ans =~ ^[Yy]$ ]] || { log INFO "Aborted."; exit 0; }
    fi
}

#################################
# Main
#################################
main() {
    check_root
    validate_config
    install_dependencies
    initialize_jail
    show_summary
    for u in $(get_site_users); do jail_user "$u"; done
    log SUCCESS "Done: all site users jailed without moving their home dirs."
}

main
