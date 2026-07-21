#!/bin/bash
# scripts/taildrop-watch.sh
# launchd entry point for ~/Library/LaunchAgents/com.nullexit.taildrop-watch.plist
# (label com.nullexit.taildrop-watch).
#
# Homebrew's tailscaled CLI (unlike the Tailscale.app GUI) does not auto-drain
# incoming Taildrop files — they sit in an internal inbox until something calls
# `tailscale file get`. This blocks in --wait --loop mode so every incoming
# file moves into ~/Downloads within moments of arriving instead of sitting
# invisible until someone remembers to pull it manually.

set -euo pipefail
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$PATH"

exec tailscale file get --wait --loop --conflict=rename "$HOME/Downloads"
