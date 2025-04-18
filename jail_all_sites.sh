#!/bin/bash
# Comment out the strict error handling for debugging
# set -euo pipefail
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
FIX_MODE=false

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
  --fix                Fix users (restore original state)

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
        --fix)        FIX_MODE=true; shift ;;
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
    echo "DEBUG: Entering validate_config" >&2
    local d; d="$(dirname "$DB_PATH")"
    echo "DEBUG: db_dir=$d" >&2
    
    if [ ! -d "$d" ]; then
        echo "DEBUG: CloudPanel directory not found: $d" >&2
        log ERROR "CloudPanel dir not found: $d"
        exit 1
    fi
    
    if [ ! -f "$DB_PATH" ]; then
        echo "DEBUG: DB not found at: $DB_PATH" >&2
        log ERROR "DB not found at: $DB_PATH"
        exit 1
    fi
    echo "DEBUG: Config validation successful" >&2
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
    local u=$1
    local user_jail="$JAIL_ROOT/$u"
    local real_home="/home/$u" 
    local jail_home_dir="$user_jail/home/$u"
    
    echo "DEBUG: Jailing user $u" >&2
    echo "DEBUG: real_home=$real_home" >&2
    echo "DEBUG: user_jail=$user_jail" >&2
    echo "DEBUG: jail_home_dir=$jail_home_dir" >&2
    
    # First ensure the user exists
    create_user "$u"
    
    # Clean up any existing jail setup
    unjail_user "$u"

    # Create and set up jail directory with proper permissions
    mkdir -p "$user_jail"
    chown root:root "$user_jail"; chmod 755 "$user_jail"
    echo "DEBUG: Set permissions on $user_jail to 755" >&2
    
    # Initialize the jail, handling errors
    if ! jk_init -v "$user_jail" basicshell netutils ssh sftp scp editors; then
        echo "DEBUG: jk_init failed for $u, creating manually" >&2
        log WARNING "jk_init failed for $u, creating manually"
    fi
    
    # Ensure all required directories exist
    mkdir -p "$user_jail/usr/sbin" "$user_jail/etc" "$user_jail/bin" "$user_jail/lib" "$user_jail/lib64"
    mkdir -p "$user_jail/home" "$jail_home_dir"
    
    # Copy the necessary binaries
    cp /usr/sbin/jk_lsh "$user_jail/usr/sbin/"; chmod 755 "$user_jail/usr/sbin/jk_lsh"
    cp /usr/sbin/jk_chrootsh "$user_jail/usr/sbin/"; chmod 755 "$user_jail/usr/sbin/jk_chrootsh"
    
    # Set up passwd and group files
    grep -E '^(root|nobody):' /etc/passwd > "$user_jail/etc/passwd"
    grep -E '^(root|nobody):' /etc/group > "$user_jail/etc/group"
    
    # Add the user to passwd in the jail with correct path
    grep "^$u:" /etc/passwd | sed "s|:/home/jail/$u/\./home/$u:|:/home/$u:|" >> "$user_jail/etc/passwd"
    grep "^$u:" /etc/group >> "$user_jail/etc/group"
    
    # Set jail permissions
    chown -R root:root "$user_jail"; chmod -R 755 "$user_jail"
    
    # -----------------------------------------------------------------------
    # CRITICAL MOUNT SECTION - Set up bind mount for home directory
    # The original site content must stay at /home/<user> for CloudPanel
    # -----------------------------------------------------------------------
    
    # Ensure real home dir exists
    echo "DEBUG: Creating real home directory $real_home if needed" >&2
    mkdir -p "$real_home"
    chown "$u:$u" "$real_home"
    chmod 755 "$real_home"
    
    # Check if jail home is already a mountpoint
    echo "DEBUG: Checking if jail home dir $jail_home_dir is a mountpoint" >&2
    if mountpoint -q "$jail_home_dir"; then
        echo "DEBUG: $jail_home_dir is already a mountpoint, unmounting first" >&2
        umount "$jail_home_dir"
    fi
    
    # Mount the real home to the jail home
    echo "DEBUG: Mounting $real_home → $jail_home_dir" >&2
    mount --bind "$real_home" "$jail_home_dir"
    
    # Verify mount was successful
    if mountpoint -q "$jail_home_dir"; then
        echo "DEBUG: Mount successful!" >&2
        log INFO "Successfully bound $real_home → $jail_home_dir (site content preserved)"
    else
        echo "DEBUG: Mount FAILED!" >&2
        log ERROR "Failed to mount $real_home → $jail_home_dir"
    fi
    
    # Set permissions on the mounted directory
    chmod 755 "$user_jail/home"
    chmod 755 "$jail_home_dir"
    chown "$u:$u" "$jail_home_dir"
    
    # Add to fstab if not already there
    if ! grep -qs "^$real_home[[:space:]]\+$jail_home_dir" /etc/fstab; then
        echo "$real_home $jail_home_dir none bind 0 0" >> /etc/fstab
        systemctl daemon-reload
        log INFO "Added fstab entry for bind-mount"
    fi
    
    # -----------------------------------------------------------------------
    # Set the user's shell safely
    local current=$(grep "^$u:" /etc/passwd)
    local prefix=${current%:*}
    sed -i "s|^$u:.*$|$prefix:/usr/sbin/jk_chrootsh|" /etc/passwd
    log INFO "Set shell to jk_chrootsh for $u"
    
    # Jail the user with the no-copy option, but handle potential failures
    echo "DEBUG: Running jk_jailuser for $u..." >&2
    if jk_jailuser -v -j "$user_jail" -s /usr/sbin/jk_chrootsh -n "$u" 2>/dev/null || true; then
        # Fix any path issues in the jail's passwd file
        sed -i "s|/\./home/|/home/|g" "$user_jail/etc/passwd" 2>/dev/null
        
        # Also fix the user's entry in the system passwd file - LEAVE HOME AT /home/<user>
        sed -i "s|$u:\([^:]*:[^:]*:[^:]*:[^:]*:[^:]*\):/home/jail/$u/\./home/$u:|$u:\1:/home/$u:|" /etc/passwd
        
        # Ensure the home directory in passwd is correct for CloudPanel
        usermod -d "/home/$u" "$u" 2>/dev/null || sed -i "s|^\($u:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*\):.*$|\1:/home/$u|" /etc/passwd
        
        # Verify user can access their home directory
        echo "DEBUG: User entry in passwd: $(grep "^$u:" /etc/passwd)" >&2
        echo "DEBUG: User entry in jail passwd: $(grep "^$u:" "$user_jail/etc/passwd")" >&2
        
        # Double-check the user's shell
        local final_shell=$(grep "^$u:" /etc/passwd | cut -d: -f7)
        echo "DEBUG: Final shell for $u: $final_shell" >&2
        
        if [ "$final_shell" = "/usr/sbin/jk_chrootsh" ]; then
            log SUCCESS "User '$u' jailed with site content preserved at /home/$u"
        else
            log WARNING "User shell may not be set correctly: $final_shell"
            # Force set it one more time
            sed -i "s|^$u:.*$|$prefix:/usr/sbin/jk_chrootsh|" /etc/passwd
            echo "DEBUG: Re-attempted to set shell: $(grep "^$u:" /etc/passwd)" >&2
        fi
    else
        log ERROR "Failed to jail '$u'"
        # If jailing failed, reset user shell
        sed -i "s|^$u:.*$|$prefix:/bin/bash|" /etc/passwd
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

# Function to fix a user's home directory and shell
fix_user() {
    local u=$1 
    local user_jail="$JAIL_ROOT/$u" 
    local jail_home_dir="$user_jail/home/$u"
    
    echo "DEBUG: Fixing user $u" >&2
    echo "DEBUG: user_jail=$user_jail, jail_home_dir=$jail_home_dir" >&2
    
    # Reset shell to bash directly in passwd file
    sed -i "s|^\($u:.*\):/usr/sbin/jk_chrootsh$|\1:/bin/bash|" /etc/passwd
    echo "DEBUG: Reset shell for $u" >&2
    
    # Reset home directory directly in passwd file
    sed -i "s|^\($u:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*\):.*$|\1:/home/$u|" /etc/passwd
    echo "DEBUG: Reset home directory for $u" >&2
    
    # Unmount any existing mounts - VERIFY CORRECT PATH
    if mountpoint -q "$jail_home_dir" 2>/dev/null; then
        echo "DEBUG: Unmounting $jail_home_dir..." >&2
        umount "$jail_home_dir"
        echo "DEBUG: Unmounted $jail_home_dir" >&2
    else
        echo "DEBUG: No mount at $jail_home_dir to unmount" >&2
    fi
    
    # Remove fstab entry - VERIFY CORRECT PATH
    if grep -qs "^/home/$u[[:space:]]\+$jail_home_dir" /etc/fstab; then
        sed -i "\#^/home/$u[[:space:]]\+$jail_home_dir#d" /etc/fstab
        systemctl daemon-reload
        echo "DEBUG: Removed fstab entry and reloaded systemd" >&2
    else
        echo "DEBUG: No fstab entry found for $jail_home_dir" >&2
    fi
    
    # Ensure home directory exists and is accessible
    mkdir -p "/home/$u"
    chown "$u:$u" "/home/$u"
    chmod 755 "/home/$u"
    
    # Force the login directory to be properly set
    echo "DEBUG: Final passwd entry for $u: $(grep "$u" /etc/passwd)" >&2
    
    log SUCCESS "Fixed user $u"
}

#################################
# Main
#################################
main() {
    echo "DEBUG: Starting main function" >&2
    check_root
    echo "DEBUG: After check_root" >&2
    
    # Check if we should fix users
    if [ "${FIX_MODE:-false}" = "true" ]; then
        for u in $(get_site_users); do
            fix_user "$u"
        done
        log SUCCESS "All users fixed."
        exit 0
    fi
    
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
