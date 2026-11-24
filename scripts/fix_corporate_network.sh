#!/bin/bash
# Remediates stale proxy variables, blocked external DNS, and invalid Ubuntu 24.04 mirror URIs
set -e

sudo mv /etc/apt/apt.conf.d/99proxy /etc/apt/apt.conf.d/99proxy.bak 2>/dev/null || true
sudo sed -i '/172\.16/d' /etc/environment
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY

sudo sed -i 's/8.8.8.8/172.16.248.2/g; /8.8.4.4/d' /etc/netplan/50-cloud-init.yaml
sudo netplan apply

sudo sed -i 's|URIs: .*|URIs: http://archive.ubuntu.com/ubuntu/|g' /etc/apt/sources.list.d/ubuntu.sources
sudo apt update
