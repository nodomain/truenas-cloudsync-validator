# TrueNAS Cloud Sync Validator

Validate encrypted TrueNAS Cloud Sync backups against remote storage (e.g., Hetzner Storage Box). Ensures your encrypted backups are bit-perfect and recoverable.

## Features

- Fetches cloud sync configuration automatically via TrueNAS REST API
- Supports encrypted rclone crypt remotes (SFTP/Hetzner Storage Box)
- Bit-perfect verification by downloading and comparing MD5 checksums
- Email notifications via TrueNAS mail system
- Lock file prevents concurrent runs
- Cron-ready for scheduled validation

## Requirements

- TrueNAS CORE 13.x (may work on SCALE with minor adjustments)
- `rclone`, `jq`, `curl` installed on the NAS
- Cloud Sync tasks configured with encryption enabled
- Email configured in TrueNAS (System → General → Email)

## Installation

```bash
# Clone or copy files to your NAS
scp validate-cloud-sync.sh .env.example user@truenas:~/

# SSH into TrueNAS
ssh user@truenas

# Setup
cp .env.example .env
chmod +x validate-cloud-sync.sh

# Edit .env with your credentials
nano .env
```

## Configuration

Edit `.env`:

```bash
TRUENAS_HOST=192.168.1.100
TRUENAS_USER=root
TRUENAS_PASSWORD=your_password

# Or use API key (recommended)
TRUENAS_API_KEY=1-xxxxxxxxxxxxxxxx
```

Generate an API key: TrueNAS UI → Top Right → API Keys

## Usage

```bash
# List all cloud sync tasks
./validate-cloud-sync.sh list

# Test connection to a task
./validate-cloud-sync.sh test 3

# Quick size-only check (fast, not bit-perfect)
./validate-cloud-sync.sh quick 3
./validate-cloud-sync.sh quick-all

# Full bit-perfect verification (downloads all files)
./validate-cloud-sync.sh validate 3
./validate-cloud-sync.sh validate-all

# Download ~50MB sample to verify decryption
./validate-cloud-sync.sh sample 3

# For cron jobs (includes email notification)
./validate-cloud-sync.sh cron

# Test email notifications
./validate-cloud-sync.sh test-email
```

## Cron Setup

TrueNAS GUI: **Tasks → Cron Jobs → Add**

| Field | Value |
|-------|-------|
| Description | Cloud Sync Validation |
| Command | `/path/to/validate-cloud-sync.sh cron` |
| Run As User | `root` |
| Schedule | Weekly (e.g., Sunday 2:00 AM) |

## How It Works

1. Fetches cloud sync task config from TrueNAS API
2. Extracts SFTP credentials and encryption password/salt
3. Generates temporary rclone config
4. Runs `rclone check --download` to verify each file:
   - Downloads encrypted file from remote
   - Decrypts using your encryption credentials
   - Computes MD5 checksum
   - Compares against local file's MD5
5. Reports results and sends email notification

## Supported Providers

Currently supports:
- SFTP (Hetzner Storage Box, any SFTP server)

## License

MIT
