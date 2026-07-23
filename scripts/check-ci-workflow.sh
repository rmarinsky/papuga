#!/usr/bin/env bash
set -euo pipefail

ci_workflow=".github/workflows/ci.yml"
release_workflow=".github/workflows/release.yml"

grep -Fq 'group: papuga-ci-${{ github.event.pull_request.number || github.ref }}' "$ci_workflow"
grep -Fq "cancel-in-progress: true" "$ci_workflow"
grep -Fq 'SWIFTPM_PACKAGES_PATH: ${{ github.workspace }}/.ci/SourcePackages' "$ci_workflow"
grep -Fq "actions/cache@v4" "$ci_workflow"
grep -Fq "papuga.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" "$ci_workflow"
grep -Fq "xcodebuild build-for-testing" "$ci_workflow"
grep -Fq "xcodebuild test-without-building" "$ci_workflow"
grep -Fq -- "-clonedSourcePackagesDirPath \"\$SWIFTPM_PACKAGES_PATH\"" "$ci_workflow"

if grep -Fq "|| xcodebuild build" "$ci_workflow"; then
  echo "CI must not repeat the full Xcode build as an output-formatting fallback" >&2
  exit 1
fi

grep -Fq 'SWIFTPM_PACKAGES_PATH: ${{ github.workspace }}/.ci/SourcePackages' "$release_workflow"
grep -Fq "actions/cache@v4" "$release_workflow"
grep -Fq -- "-clonedSourcePackagesDirPath \"\$SWIFTPM_PACKAGES_PATH\"" "$release_workflow"

if grep -A8 "actions/cache@v4" "$ci_workflow" | grep -Eq "DerivedData|xcarchive|certificate"; then
  echo "CI cache must contain only resolved Swift package sources" >&2
  exit 1
fi
