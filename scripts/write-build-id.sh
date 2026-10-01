#!/bin/sh
# Pre-build script (project.yml, Kronos target): stamps the running git short hash into the
# built Info.plist as KronosBuildID, so Settings > General can show it after the version
# (owner: "jednom testirao stari build" — a build id makes a stale copy obvious at a glance).
# Falls back to "dev" outside a git checkout (a source-only distribution, a CI cache miss, or
# `git` simply missing) so the build never fails for a cosmetic value.
set -e
BUILD_ID="$(git -C "$SRCROOT" rev-parse --short HEAD 2>/dev/null || echo dev)"
# Uncommitted changes get a suffix from their diff, so two different working trees on the
# same commit never show the same id (the broken 28.09. demo and its fix both said e64650b).
if [ "$BUILD_ID" != dev ] && ! git -C "$SRCROOT" diff --quiet HEAD 2>/dev/null; then
  BUILD_ID="$BUILD_ID+$(git -C "$SRCROOT" diff HEAD | shasum | cut -c1-6)"
fi
PLIST="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
/usr/libexec/PlistBuddy -c "Delete :KronosBuildID" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :KronosBuildID string $BUILD_ID" "$PLIST"
