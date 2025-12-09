# Copilot Instructions for RedArrow Scripts Repository

## Repository Overview

This is a personal utility scripts collection supporting cross-platform terminal/shell environments (PowerShell, Bash) with integrations for AWS, Kubernetes, Docker, and monitoring tools.

## File Organization Pattern

- **PowerShell scripts**: Use `Verb-NounDescription.ps1` format (e.g., `Expand-BatchZipContent.ps1`, `Fix-FilenamesInCurrentDir.ps1`)
- **Bash scripts**: Use `kebab-case` without `.sh` for executables in `bash/admin-scripts/` (e.g., `portainer-update`)
- **Utility bash scripts**: Include `.sh` extension for library/helper scripts (e.g., `test-slack-webhook.sh`)
- **Theme files**: JSON format for Oh My Posh themes in `themes/oh-my-posh/`; Windows Terminal themes in `themes/Terminal/` are reference files only

## PowerShell Conventions

### Script Structure

All PowerShell scripts follow advanced function patterns with:

- `[CmdletBinding()]` for common parameters (`-Verbose`, `-WhatIf`)
- Comprehensive comment-based help (`.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, `.EXAMPLE`)
- Pipeline support via `ValueFromPipeline` where applicable
- Example: See `Expand-BatchZipContent.ps1` for the standard template

### Profile Integration

The `PowerShell_Profile.ps1` demonstrates environment-aware theming:

- **Cloud context detection**: Uses `$env:AWS_PROFILE` to switch Oh My Posh themes
- **Theme switching**: `cloud-context.omp.json` when AWS profile active, `clean-detailed.omp.json` otherwise
- **Standard imports**: `posh-git` and `oh-my-posh` modules expected

## Bash Script Patterns

### Error Handling

All bash scripts use strict error handling:

```bash
set -eo pipefail  # Exit on error, pipe failures
```

### Logging Standard

Scripts include consistent logging functions:

```bash
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}
```

### Slack Integration

Notification scripts follow this pattern (see `test-slack-webhook.sh`, `portainer-update`):

- Default payload location: `${SCRIPT_DIR}/slack-payload.json`
- Webhook URL via environment variable or argument: `${SLACK_WEBHOOK_URL}`
- JSON validation using `jq empty`
- Structured logging to `slack-webhook-test.log`

### Admin Scripts

Scripts in `bash/admin-scripts/` are executable (no `.sh`):

- Docker management (e.g., `portainer-update` for container lifecycle)
- Require dependency checks: `command -v docker &>/dev/null`
- Service state validation: `systemctl is-active --quiet docker`

## Environment-Specific Utilities

### WSL Networking

`repair-wsl-networking.sh` uses immutable file pattern:

```bash
chattr +i /etc/resolv.conf  # Prevent WSL from overwriting DNS
```

### Cross-Platform Build Optimization

`optimize-cmake-builder.sh` detects CPU cores per OS:

- Linux: `nproc`
- macOS: `sysctl -n hw.physicalcpu`
- BSD: `sysctl -n hw.ncpu`

## Oh My Posh Theming

Themes in `themes/oh-my-posh/` use conditional segments:

- **cloud-context.omp.json**: Shows AWS, Kubernetes (`kubectl`), and Talos (`talosctl`) context
- Palette convention: `p:cloud-text-amazon`, `p:kubernetes-text`, `p:timer-text`
- Console title template includes Git repo name and root status

## When Creating New Scripts

### PowerShell

1. Start with `[CmdletBinding(SupportsShouldProcess)]` template
2. Include parameter validation: `[ValidateScript({ Test-Path $_ })]`
3. Use `.NET` classes for advanced operations (e.g., `System.IO.Compression.ZipFile`)
4. Implement conflict resolution for file operations (see zip extractor's counter logic)

### Bash

1. Include `set -eo pipefail` at the top
2. Add `usage()` function and `--help` support
3. Validate dependencies with `command -v` checks
4. Use `SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"` for relative paths
5. For Slack notifications, integrate with `/opt/slack-bash-notifications` pattern

## Testing Commands

- **PowerShell syntax**: `pwsh -NoProfile -Command "& './script.ps1' -WhatIf"`
- **Bash syntax**: `shellcheck script.sh`
- **JSON validation**: `jq empty file.json`

## Common Integration Points

- **AWS**: Scripts check `$env:AWS_PROFILE` (PowerShell) or `$AWS_PROFILE` (Bash)
- **Slack webhooks**: Centralized in environment variable `SLACK_WEBHOOK_URL`
- **Docker**: Admin scripts assume Docker daemon managed by systemd
- **Oh My Posh**: Installed to `/usr/bin` (Linux) or `$HOME/.local/bin` via official installer
- **Monitoring**: Prometheus exporters (`node_exporter`) integrate with Grafana dashboards

## Deployment Pattern

- **Bash home directory**: Scripts in `bash/home/` are deployed to Linux user home directories (`~/.local/bin`, `~/.bashrc`, etc.)
- **Admin scripts**: Located in `bash/admin-scripts/` for system-level operations
- **Slack notifications**: Centralized in `/opt/slack-bash-notifications` for shared access
