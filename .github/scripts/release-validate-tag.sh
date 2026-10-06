#!/usr/bin/env bash
# Validate a release tag against SemVer 2.0.0 and print the workflow outputs.
#
# Usage: release-validate-tag.sh <tag>
#
# Prints `tag=`, `version=` and `prerelease=` lines suitable for appending to
# $GITHUB_OUTPUT. The tag must be `v<major>.<minor>.<patch>` optionally followed
# by `-<prerelease>` and `+<build>` exactly as semver.org defines them; anything
# else exits non-zero so no build starts from a tag the binary could not report.
set -euo pipefail

tag="${1:?usage: release-validate-tag.sh <tag>}"

# The official SemVer 2.0.0 regular expression, with a mandatory `v` prefix.
numeric='(0|[1-9][0-9]*)'
ident='(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
pre="(-${ident}(\\.${ident})*)?"
build='(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?'
semver="^v${numeric}\\.${numeric}\\.${numeric}${pre}${build}\$"

if [[ ! "$tag" =~ $semver ]]; then
  echo "FAIL: tag '$tag' is not v<major>.<minor>.<patch>[-prerelease][+build] (SemVer 2.0.0)" >&2
  exit 1
fi

version="${tag#v}"
core="${version%%[-+]*}"
rest="${version#"$core"}"
prerelease=false
if [[ "$rest" == -* ]]; then
  prerelease=true
fi

echo "PASS: tag '$tag' is SemVer 2.0.0 (version $version, prerelease $prerelease)" >&2
printf 'tag=%s\n' "$tag"
printf 'version=%s\n' "$version"
printf 'prerelease=%s\n' "$prerelease"
