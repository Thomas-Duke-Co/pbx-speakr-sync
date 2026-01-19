# PBX Speakr Sync

Unattended sync of PBX call recordings to Speakr. Designed to run via cron or launchd.

## Features

- **Automatic pull** - Syncs recordings from PBX via rsync over SSH
- **Extension filtering** - Only uploads calls for specified extension
- **Duplicate prevention** - SHA256 hash tracking prevents re-uploading
- **Logging** - Full activity log for troubleshooting
- **Configurable** - All settings via config file

## Requirements

- macOS (uses `stat -f` for file size)
- SSH key access to PBX server
- Speakr account with API access

## Setup

1. Clone this repository
2. Copy config files:

```bash
mkdir -p ~/.config/speakr
cp sync.conf.example ~/.config/speakr/sync.conf
cp auth.env.example ~/.config/speakr/auth.env
```

3. Edit `~/.config/speakr/sync.conf` with your PBX details
4. Edit `~/.config/speakr/auth.env` with your Speakr credentials
5. Ensure SSH key access to PBX:

```bash
ssh-copy-id -p 22 root@your-pbx-host
```

## Usage

### Manual run

```bash
./pbx_speakr_sync.sh
```

### Scheduled via cron (every 15 minutes)

```bash
crontab -e
```

Add:
```
*/15 * * * * /path/to/pbx_speakr_sync.sh >> /dev/null 2>&1
```

### Scheduled via launchd (macOS)

Create `~/Library/LaunchAgents/com.speakr.pbx-sync.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.speakr.pbx-sync</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/YOUR_USERNAME/pbx_speakr_sync.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>900</integer>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
```

Load it:
```bash
launchctl load ~/Library/LaunchAgents/com.speakr.pbx-sync.plist
```

## Configuration

### sync.conf

| Variable | Default | Description |
|----------|---------|-------------|
| `PBX_HOST` | thomasduke.crosstalksolutions.com | PBX hostname |
| `PBX_USER` | root | SSH user |
| `PBX_PORT` | 22 | SSH port |
| `REMOTE_DIR` | /var/spool/asterisk/monitor/ | Remote recordings path |
| `EXT` | 1104 | Extension to filter |
| `BASE` | ~/pbx_recordings | Local storage base path |

### auth.env

See [pbx-speakr-review](https://github.com/trevoreduke/pbx-speakr-review) for credential extraction instructions.

## Directory Structure

```
~/pbx_recordings/
├── monitor/              # All recordings from PBX
├── ext_1104/             # Filtered by extension (preserves structure)
├── ext_1104_flat/        # Flattened for upload
├── uploaded_to_speakr/   # Successfully uploaded
├── failed_speakr/        # Failed uploads
└── sync.log              # Activity log
```

## Log File

Activity is logged to `~/pbx_recordings/sync.log`:

```
[2026-01-19 17:30:00] ========== PBX Speakr Sync Started ==========
[2026-01-19 17:30:00] PBX: root@pbx.example.com:/var/spool/asterisk/monitor/
[2026-01-19 17:30:00] Extension filter: 1104
[2026-01-19 17:30:05] ==> Step 1: Pulling recordings from PBX
[2026-01-19 17:30:10] ==> Step 2: Filtering extension 1104
[2026-01-19 17:30:11] ==> Step 3: Flattening directory structure
[2026-01-19 17:30:11] ==> Step 4: Uploading to Speakr
[2026-01-19 17:30:12] [UPLOAD] external-1104-5551234567-20260119-093000.wav
[2026-01-19 17:30:15] [OK] Uploaded (HTTP 202) RecordingID=42
[2026-01-19 17:30:15] ========== Sync Complete: 1 files processed ==========
```

## Related

- [pbx-speakr-review](https://github.com/trevoreduke/pbx-speakr-review) - Interactive review tool (manual approval before upload)

## License

MIT
