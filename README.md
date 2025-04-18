# CloudPanel Site Jailer

A Bash utility that automatically discovers all site users in your CloudPanel installation and jails each one into a JailKit‑powered chroot environment—preserving SSH/SFTP access while enforcing per‑site isolation for enhanced security.

## Features

- Auto-installs and configures JailKit
- Scans CloudPanel's SQLite database for site users
- Initializes a reusable chroot at `/home/jail`
- Jails each user with `jk_jailuser` (including ssh, sftp, scp)
- Logs actions for auditability and troubleshooting
- Color-coded output for better visibility
- Comprehensive error handling and validation
- Command-line options for customization
- Interactive confirmation prompts
- Configuration summary before execution

## Prerequisites

- CloudPanel installation
- Root or sudo access
- Internet connection (for initial JailKit installation)
- SQLite3 (will be installed if missing)
- JailKit (will be installed if missing)

## Installation

1. Clone this repository:
```bash
git clone https://github.com/rick001/cloudpanel-site-jailer.git
cd cloudpanel-site-jailer
```

2. Make the script executable:
```bash
chmod +x jail_all_sites.sh
```

## Usage

### Basic Usage
Run the script as root or with sudo:
```bash
sudo ./jail_all_sites.sh
```

### Command Line Options
```bash
-h, --help           Show help message
-d, --db-path PATH   Specify custom CloudPanel database path
-j, --jail-root PATH Specify custom jail root directory
-l, --log-file PATH  Specify custom log file path
-v, --verbose        Enable verbose output
-y, --yes            Skip confirmation prompts
```

### Examples

1. Basic usage with confirmation:
```bash
sudo ./jail_all_sites.sh
```

2. Custom paths:
```bash
sudo ./jail_all_sites.sh --db-path /custom/path/db.sq3 --jail-root /custom/jail
```

3. Skip confirmation:
```bash
sudo ./jail_all_sites.sh --yes
```

4. Show help:
```bash
sudo ./jail_all_sites.sh --help
```

The script will:
1. Check for and install JailKit if not present
2. Initialize the jail environment at `/home/jail` (or custom path)
3. Scan your CloudPanel database for site users
4. Show a summary of users to be jailed
5. Ask for confirmation (unless -y is used)
6. Jail each user while preserving SSH/SFTP access
7. Log all actions to the specified log file

### Example Output
```
[2024-03-14 10:30:00] Configuration Summary:
[2024-03-14 10:30:00]   Database Path: /home/clp/htdocs/app/data/db.sq3
[2024-03-14 10:30:00]   Jail Root: /home/jail
[2024-03-14 10:30:00]   Log File: /var/log/jail_all_sites.log
[2024-03-14 10:30:00] Users to be jailed:
[2024-03-14 10:30:00]   - example1
[2024-03-14 10:30:00]   - example2

Do you want to continue? (y/n) y

[2024-03-14 10:30:05] Installing jailkit...
[2024-03-14 10:30:10] Initializing JailKit environment at /home/jail
[2024-03-14 10:30:15] User example1 jailed successfully
[2024-03-14 10:30:20] User example2 jailed successfully
[2024-03-14 10:30:25] Site-jailing process completed
```

## Configuration

The script uses the following default paths:
- CloudPanel DB: `/home/clp/htdocs/app/data/db.sq3`
- Jail root: `/home/jail`
- Log file: `/var/log/jail_all_sites.log`

You can modify these paths either by:
1. Editing the variables at the top of the script
2. Using command-line options when running the script

## Logging

All actions are logged to the specified log file with timestamps, including:
- Installation steps
- User discovery
- Jail operations
- Success/failure status for each operation
- Configuration summary
- User confirmations

## Troubleshooting

### Common Issues

1. **Permission Denied**
   - Ensure you're running the script as root or with sudo
   - Check that the script has execute permissions

2. **Database Not Found**
   - Verify your CloudPanel installation path
   - Check if the database file exists at the expected location
   - Use --db-path to specify a custom path

3. **JailKit Installation Failed**
   - Check your internet connection
   - Ensure apt-get has proper access to repositories

4. **User Already Jailed**
   - The script will skip users that are already in jail
   - No action needed, this is normal behavior

### Checking Logs

To view the latest logs:
```bash
tail -f /var/log/jail_all_sites.log
```

## Security Benefits

- Per-site isolation through chroot environments
- Preserved SSH/SFTP functionality
- Enhanced security through user confinement
- Automatic discovery and configuration
- Secure logging of all operations
- Interactive confirmation for safety

## Best Practices

1. **Backup First**
   - Always backup your CloudPanel installation before running the script
   - Consider creating a system snapshot if using a VPS

2. **Monitor After Installation**
   - Check the logs after running the script
   - Verify SSH/SFTP access for each jailed user
   - Test website functionality

3. **Regular Maintenance**
   - Review logs periodically
   - Update JailKit when new versions are available
   - Monitor system resources

## License

MIT License

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Support

For issues and feature requests, please use the [GitHub Issues](https://github.com/rick001/cloudpanel-site-jailer/issues) page. 