# PVE_EXPORTER SETUP AND CONFIGURATION

## RUN

```bash
export PVE_API_USER='prometheus@pve'
export PVE_TOKEN_NAME='prometheus@pve!prometheus'
export PVE_TOKEN_SECRET='Y62f75bf8-74af-45bb-93d7-9f4486867d33'

sudo env \
  PVE_API_USER="$PVE_API_USER" \
  PVE_TOKEN_NAME="$PVE_TOKEN_NAME" \
  PVE_TOKEN_SECRET="$PVE_TOKEN_SECRET" \
  PVE_VERIFY_SSL=false \
  bash setup-prometheus-pve-exporter.sh
```
