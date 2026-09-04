#!/bin/bash
# Hardened descriptor-relative storage entry point for Omarchy Notifications Settings
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec /usr/bin/python3 -u "$dir/storage.py" "$@"
