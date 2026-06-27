#!/bin/bash
# Build (and launch) the CEC Dashboard .app (Debug, ad-hoc signed).
# Regenerates the Xcode project from project.yml first, so it works from a fresh
# checkout. Usage:  ./build.sh [--no-open]
set -euo pipefail
cd "$(dirname "$0")"

xcodegen generate
xcodebuild -project CECDashboard.xcodeproj -scheme CECDashboard \
  -configuration Debug -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build

APP="build/Build/Products/Debug/CECDashboard.app"
echo "Built $APP"
[[ "${1:-}" == "--no-open" ]] || open "$APP"
