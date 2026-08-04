# PYTHON-UNIFI

## SETUP

### Setup your credentials


```bash
# Linux setup
export UNIFI_HOST="https://your-unifi.local/proxy/network/integration"
export UNIFI_API_KEY="your-64-hex-key"
```

```powershell
$ENV:UNIFI_HOST="https://your-unifi.local/proxy/network/integration"
$ENV:UNIFI_API_KEY="your-64-hex-key"
```

## RUN

```bash
# Run the script – uv creates an ephemeral venv and installs requests
uv run --with requests python unifi_list_clients.py
```
