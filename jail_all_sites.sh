#!/bin/bash
set -euo pipefail

# Configuration
DB_PATH="/home/clp/htdocs/app/data/db.sq3"
JAIL_ROOT="/home/jail"
LOGFILE="/var/log/jail_all_sites.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to display help
show_help() {
    echo -e "${BLUE}CloudPanel Site Jailer${NC}"
    echo "A utility to jail CloudPanel site users in chroot environments"
    echo
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  -h, --help           Show this help message"
    echo "  -d, --db-path PATH   Specify custom CloudPanel database path"
    echo "  -j, --jail-root PATH Specify custom jail root directory"
    echo "  -l, --log-file PATH  Specify custom log file path"
    echo "  -v, --verbose        Enable verbose output"
    echo "  -y, --yes            Skip confirmation prompts"
    echo
    echo "Example:"
    echo "  $0 --db-path /custom/path/db.sq3 --jail-root /custom/jail"
    exit 0
}

# Parse command line arguments
VERBOSE=false
SKIP_CONFIRM=false
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            ;;
        -d|--db-path)
            DB_PATH="$2"
            shift 2
            ;;
        -j|--jail-root)
            JAIL_ROOT="$2"
            shift 2
            ;;
        -l|--log-file)
            LOGFILE="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -y|--yes)
            SKIP_CONFIRM=true
            shift
            ;;
        *)
            log "ERROR" "Unknown option: $1"
            show_help
            ;;
    esac
done

# Function to log messages with color
log() {
    local level=$1
    local message=$2
    local color=$NC
    
    case $level in
        "ERROR") color=$RED ;;
        "SUCCESS") color=$GREEN ;;
        "WARNING") color=$YELLOW ;;
        "INFO") color=$BLUE ;;
    esac
    
    echo -e "${color}[$(date +'%F %T')] $message${NC}" | tee -a "$LOGFILE"
}

# Function to check if running as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log "ERROR" "This script must be run as root"
        exit 1
    fi
}

# Function to validate configuration
validate_config() {
    if [ ! -d "$(dirname "$DB_PATH")" ]; then
        log "ERROR" "CloudPanel installation directory not found"
        exit 1
    fi
    
    if [ ! -f "$DB_PATH" ]; then
        log "ERROR" "CloudPanel database not found at $DB_PATH"
        exit 1
    fi
    
    if [ ! -d "$(dirname "$LOGFILE")" ]; then
        mkdir -p "$(dirname "$LOGFILE")"
    fi
}

# Function to install dependencies
install_dependencies() {
    for cmd in sqlite3 jk_init jk_jailuser; do
        if ! command -v "$cmd" &> /dev/null; then
            if [ "$cmd" = "sqlite3" ]; then
                log "ERROR" "sqlite3 is required but missing"
                exit 1
            fi
            log "WARNING" "Installing jailkit..."
            apt-get update
            apt-get install -y jailkit
            break
        fi
    done
}

# Function to initialize jail
initialize_jail() {
    if [ ! -d "$JAIL_ROOT" ]; then
        log "WARNING" "Initializing JailKit environment at $JAIL_ROOT"
        jk_init -v "$JAIL_ROOT" basicshell netutils ssh sftp scp editors
    fi
}

# Function to get site users
get_site_users() {
    local users
    mapfile -t users < <(sqlite3 "$DB_PATH" \
        "SELECT DISTINCT user FROM site WHERE user IS NOT NULL AND user != '';")
    echo "${users[@]}"
}

# Function to jail user
jail_user() {
    local user=$1
    if id "$user" &> /dev/null; then
        if jk_jailuser -v -j "$JAIL_ROOT" "$user"; then
            log "SUCCESS" "User $user jailed successfully"
        else
            log "ERROR" "Failed to jail user $user"
        fi
    else
        log "WARNING" "User $user does not exist on this system, skipping"
    fi
}

# Function to show summary before execution
show_summary() {
    log "INFO" "Configuration Summary:"
    log "INFO" "  Database Path: $DB_PATH"
    log "INFO" "  Jail Root: $JAIL_ROOT"
    log "INFO" "  Log File: $LOGFILE"
    
    local site_users
    mapfile -t site_users < <(get_site_users)
    
    if [ ${#site_users[@]} -eq 0 ]; then
        log "WARNING" "No site users found in database"
    else
        log "INFO" "Users to be jailed:"
        for user in "${site_users[@]}"; do
            log "INFO" "  - $user"
        done
    fi
    
    if [ "$SKIP_CONFIRM" = false ]; then
        echo
        read -p "Do you want to continue? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "INFO" "Operation cancelled by user"
            exit 0
        fi
    fi
}

# Main execution
main() {
    check_root
    validate_config
    install_dependencies
    initialize_jail
    show_summary
    
    local site_users
    mapfile -t site_users < <(get_site_users)
    
    if [ ${#site_users[@]} -eq 0 ]; then
        log "WARNING" "No site users found in DB – nothing to jail"
        exit 0
    fi
    
    for site_user in "${site_users[@]}"; do
        jail_user "$site_user"
    done
    
    log "SUCCESS" "Site-jailing process completed"
}

# Start the script
main
