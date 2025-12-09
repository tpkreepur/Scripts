#!/bin/bash

# This script installs the following Prometheus exporters on a Linux machine:
# - Node Exporter
# - Disk Usage Exporter
# - Nvidia GPU Exporter (optional)
# It will download the latest release from the official GitHub repository
# and install it as a service

install_path="/usr/local/bin"
temp_path="/tmp"

# Set the architecture based on uname output
# If arch is x86_64, set it to amd64
if [ "$(uname -m)" == "x86_64" ]; then
  arch="amd64"
fi

os="$(uname -s | tr '[:upper:]' '[:lower:]')"

# Check if the script is run as sudo
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit
fi

os_release_check() {
  if [ -f /etc/os-release ]; then
    source /etc/os-release
    if [ "$ID" == "ubuntu" ]; then
      echo "Ubuntu detected - using apt package manager"
      PKG_MANAGER="apt"
    fi
  else
    echo "Unsupported OS"
    exit
  fi
}

# Install the Node Exporter
install_node_exporter() {
  # Check if the Node Exporter is already installed
  if [ -f /usr/local/bin/node_exporter ]; then
    echo "Node Exporter is already installed"
    exit
  fi

  version="1.8.2"

  # Download url for the Node Exporter
  file_url="https://github.com/prometheus/node_exporter/releases/download/v${version}/node_exporter-${version}.${os}-${arch}.tar.gz"


  # Download the file
  echo "Downloading Node Exporter from latest GitHub release"
  wget -P $temp_path $file_url

  # Extract the downloaded file
  tar -xzf $temp_path/node_exporter-*.*-*.tar.gz -C $temp_path

  # Move the binary to $install_path
  mv $temp_path/node_exporter-${version}.${os}-${arch}/node_exporter $install_path

  # Create a service file for the Node Exporter
  cat <<EOF >/etc/systemd/system/node_exporter.service
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
ExecStart=$install_path/node_exporter

[Install]
WantedBy=default.target
EOF

  # Reload the systemd daemon
  systemctl daemon-reload

  # Start the Node Exporter service
  systemctl start node_exporter

  # Enable the Node Exporter service to start on boot
  systemctl enable node_exporter

  # Check the status of the Node Exporter service
  systemctl status node_exporter

  echo "Node Exporter installed successfully"
}

# Install the Disk Usage Exporter
install_disk_usage_exporter() {
  version="0.6.0"

  # Download url for the Disk Usage Exporter
  file_url="https://github.com/dundee/disk_usage_exporter/releases/download/v${version}/disk_usage_exporter_${os}_${arch}.tgz"

  # Download the file
  echo "Downloading Disk Usage Exporter from latest GitHub release"
  wget -P $temp_path $file_url

  # Extract the downloaded file
  tar -xzf $temp_path/disk_usage_exporter_*_*.tgz -C $temp_path

  # Move the binary to $install_path
  mv $temp_path/disk_usage_exporter $install_path

  # Create a service file for the Disk Usage Exporter
  cat <<EOF >/etc/systemd/system/disk_usage_exporter.service
[Unit]
Description=Prometheus disk usage exporter
After=node_exporter.service
Documentation=https://github.com/dundee/disk_usage_exporter

[Service]
Restart=always
User=prometheus
ExecStart=$install_path
/disk_usage_exporter $ARGS
ExecReload=/bin/kill -HUP $MAINPID
TimeoutStopSec=20s
SendSIGKILL=no

[Install]
WantedBy=multi-user.target
}

install_prerequisites() {
  # install go DiskUsage() based on the OS's package manager
  if [ "$PKG_MANAGER" == "apt" ]; then
    apt update
    apt install -y gdu
  fi

}

install_node_exporter
