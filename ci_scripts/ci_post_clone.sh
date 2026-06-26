#!/bin/sh
#
# ci_post_clone.sh — Xcode Cloud hook, runs after the repo is cloned.
#
# Installs SwiftLint via Homebrew so the "Run SwiftLint" build phase in
# the Murmur target can invoke it. Murmur used to pull SwiftLint via the
# SPM build-tool plugin, which forced Xcode Cloud trust workarounds and
# blocked other SPM deps (swift-snapshot-testing couldn't co-resolve with
# SwiftLint's swift-syntax pin). Moving lint to brew + Run Script kept
# the lint gate but freed the package graph.
#
# Homebrew is pre-installed on Xcode Cloud runners.
#

set -euo pipefail

echo "ci_post_clone: installing SwiftLint"
brew install swiftlint
swiftlint --version

echo "ci_post_clone: done"
