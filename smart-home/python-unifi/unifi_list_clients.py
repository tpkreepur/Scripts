#!/usr/bin/env python3
"""
UniFi Network API - List All Connected Clients

This script fetches all currently connected clients from your UniFi Network
Application using the official API.
"""

import json
import os
import sys
from typing import Any, Dict, List

import requests

# =============================================================================
# CONFIGURATION
# =============================================================================

# Your UniFi Network Application base URL (local controller)
# Example: "https://192.168.1.1" or "https://unifi.yourdomain.com"
UNIFI_HOST = os.environ.get("UNIFI_HOST", "https://your-unifi-controller.local")

# API Key - generate at unifi.ui.com → Settings → Control Plane → Integrations[reference:0][reference:1]
UNIFI_API_KEY = os.environ.get("UNIFI_API_KEY", "your-api-key-here")

# Verify SSL certificate (set to False if using self-signed certs)
VERIFY_SSL = (
    os.environ.get("UNIFI_VERIFY_SSL", "false").lower() == "true"
)  # default to False for self-signed


# =============================================================================
# API CLIENT
# =============================================================================


class UniFiNetworkClient:
    """Simple client for the UniFi Network API."""

    def __init__(self, host: str, api_key: str, verify_ssl: bool = False):
        self.host = host.rstrip("/")
        self.api_key = api_key
        self.verify_ssl = verify_ssl
        self.session = requests.Session()
        self.session.headers.update(
            {
                "X-API-KEY": api_key,
                "Accept": "application/json",
            }
        )

    def _request(self, method: str, path: str, **kwargs) -> Dict[str, Any]:
        """Make an authenticated API request."""
        url = f"{self.host}{path}"
        kwargs.setdefault("verify", self.verify_ssl)
        response = self.session.request(method, url, **kwargs)
        response.raise_for_status()
        return response.json()

    def get_sites(self) -> List[Dict[str, Any]]:
        """List all sites available to this API key.[reference:2]"""
        data = self._request("GET", "/v1/sites")
        return data.get("data", [])

    def get_connected_clients(self, site_id: str) -> List[Dict[str, Any]]:
        """
        List all currently connected clients for a site.[reference:3]

        Returns a list of client objects with details like:
        - macAddress, ipAddress, hostname
        - connectedAt (timestamp)
        - type ("WIRED" or "WIRELESS")
        - ssid (if wireless), channel, rssi, etc.
        """
        data = self._request("GET", f"/v1/sites/{site_id}/clients")
        return data.get("data", [])


# =============================================================================
# MAIN
# =============================================================================


def main():
    # Validate configuration
    if UNIFI_API_KEY == "your-api-key-here":
        print(
            "ERROR: Please set your UNIFI_API_KEY environment variable or edit the script."
        )
        print("Generate one at: unifi.ui.com → Settings → Control Plane → Integrations")
        sys.exit(1)

    if UNIFI_HOST == "https://your-unifi-controller.local":
        print(
            "ERROR: Please set your UNIFI_HOST environment variable or edit the script."
        )
        sys.exit(1)

    client = UniFiNetworkClient(UNIFI_HOST, UNIFI_API_KEY, VERIFY_SSL)

    try:
        # 1. Get all sites
        print("Fetching sites...")
        sites = client.get_sites()
        if not sites:
            print("No sites found. Check your API key permissions.")
            sys.exit(1)

        # 2. For each site, fetch connected clients
        all_clients = []
        for site in sites:
            site_id = site.get("id")
            site_name = site.get("name", site_id)
            print(f"Fetching clients for site: {site_name} ({site_id})")
            clients = client.get_connected_clients(site_id)
            print(f"  Found {len(clients)} connected clients")
            all_clients.extend(clients)

        # 3. Print results
        print("\n" + "=" * 60)
        print(f"TOTAL CONNECTED CLIENTS: {len(all_clients)}")
        print("=" * 60)

        for idx, cl in enumerate(all_clients, 1):
            print(f"\n[{idx}] {cl.get('hostname', 'Unknown')}")
            print(f"    MAC:      {cl.get('macAddress', 'N/A')}")
            print(f"    IP:       {cl.get('ipAddress', 'N/A')}")
            print(f"    Type:     {cl.get('type', 'N/A')}")
            if cl.get("type") == "WIRELESS":
                print(f"    SSID:     {cl.get('ssid', 'N/A')}")
                print(f"    Channel:  {cl.get('channel', 'N/A')}")
                print(f"    RSSI:     {cl.get('rssi', 'N/A')} dBm")
            print(f"    Connected: {cl.get('connectedAt', 'N/A')}")

        # 4. Optionally save full JSON output
        # with open("clients.json", "w") as f:
        #     json.dump(all_clients, f, indent=2, default=str)

    except requests.exceptions.SSLError:
        print("SSL certificate verification failed. Try setting VERIFY_SSL = False")
        print(
            "(Only do this if you're using a self-signed certificate and understand the risks.)"
        )
        sys.exit(1)
    except requests.exceptions.RequestException as e:
        print(f"Request failed: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
