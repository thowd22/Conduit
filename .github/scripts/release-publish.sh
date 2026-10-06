#!/usr/bin/env bash
# Create or update the GitHub release for a tag and upload the artifacts.
#
# Usage: release-publish.sh <tag> <version> <prerelease:true|false> <dist-dir>
#
# Rerunning for the same tag is safe: an existing release is reused and its
# prerelease flag corrected, and `--clobber` replaces assets of the same name
# instead of failing or duplicating them. Requires `gh` with GH_TOKEN granting
# `contents: write`.
set -euo pipefail

tag="${1:?usage: release-publish.sh <tag> <version> <prerelease> <dist-dir>}"
version="${2:?usage: release-publish.sh <tag> <version> <prerelease> <dist-dir>}"
prerelease="${3:?usage: release-publish.sh <tag> <version> <prerelease> <dist-dir>}"
dist="${4:?usage: release-publish.sh <tag> <version> <prerelease> <dist-dir>}"

case "$prerelease" in
  true|false) ;;
  *) echo "FAIL: prerelease must be true or false, got '$prerelease'" >&2; exit 1 ;;
esac

shopt -s nullglob
assets=("$dist"/*.tar.gz "$dist"/*.deb "$dist"/*.AppImage "$dist"/SHA256SUMS)
[ "${#assets[@]}" -ge 4 ] || { echo "FAIL: expected tar.gz, deb, AppImage and SHA256SUMS in $dist" >&2; exit 1; }

notes_header="Linux x86_64 release $version. macOS and Windows artifacts are deferred to TASK-69."
if gh release view "$tag" > /dev/null 2>&1; then
  echo "INFO: release $tag exists; updating it in place"
  gh release edit "$tag" --title "Conduit $version" --prerelease="$prerelease" > /dev/null
else
  create_args=(--verify-tag --title "Conduit $version" --generate-notes --notes "$notes_header")
  if [ "$prerelease" = true ]; then
    create_args+=(--prerelease)
  fi
  gh release create "$tag" "${create_args[@]}" > /dev/null
  echo "PASS: created release $tag (prerelease=$prerelease)"
fi

gh release upload "$tag" "${assets[@]}" --clobber
echo "PASS: uploaded ${#assets[@]} assets to $tag with --clobber"
gh release view "$tag" --json name,isPrerelease,assets --jq '"INFO: " + .name + " prerelease=" + (.isPrerelease|tostring) + " assets=" + ([.assets[].name] | join(", "))'
