#!/bin/sh
# Pre-build script (project.yml, Kronos target): stamps the running git short hash into the
# built Info.plist as KronosBuildID, so Settings > General can show it after the version
# (owner: "jednom testirao stari build" — a build id makes a stale copy obvious at a glance).
# Falls back to "dev" outside a git checkout (a source-only distribution, a CI cache miss, or
# `git` simply missing) so the build never fails for a cosmetic value.
set -e
BUILD_ID="$(git -C "$SRCROOT" rev-parse --short HEAD 2>/dev/null || echo dev)"
PLIST="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
/usr/libexec/PlistBuddy -c "Delete :KronosBuildID" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :KronosBuildID string $BUILD_ID" "$PLIST"
