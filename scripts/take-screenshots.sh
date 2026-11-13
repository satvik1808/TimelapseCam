#!/bin/bash
# Captures the Timelapse Cam window into docs/screenshots.
# Needs Screen Recording permission for your terminal (System Settings > Privacy & Security).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p docs/screenshots
open TimelapseCam.app
sleep 3
echo "Click the Timelapse Cam window to capture it (main view)..."
screencapture -o -w docs/screenshots/main-window.png
echo "Now open Settings (⌘,) and press Return to capture it."
read -r _
screencapture -o -w docs/screenshots/settings.png
echo "Saved screenshots to docs/screenshots/"
