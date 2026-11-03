#!/bin/bash
# Publish a new version that installed copies of Tacho will offer to update to.
#
#   ./release.sh 1.1.0 "What changed"
#
# Bumps VERSION, builds the .dmg and its .sha256, commits, tags v<version>,
# pushes, and creates the GitHub release with both files attached (needs the
# GitHub CLI, `gh`; without it the last step is printed for doing by hand).
set -euo pipefail

cd "$(dirname "$0")"

VERSION="${1:?usage: ./release.sh <version> [notes]}"
NOTES="${2:-}"
TAG="v${VERSION}"
REPO="hieupnvmg/Tacho"

if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "Version must look like 1.2.0" >&2
    exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
    echo "Commit or stash your changes first." >&2
    exit 1
fi

echo "$VERSION" > VERSION
./build-dmg.sh

# Releasing the version already in VERSION (the first release) has nothing to commit.
if ! git diff --quiet -- VERSION; then
    git add VERSION
    git commit -m "Release ${TAG}"
fi
git tag -a "$TAG" -m "Tacho ${VERSION}"
git push origin HEAD "$TAG"

if command -v gh >/dev/null 2>&1; then
    gh release create "$TAG" --repo "$REPO" --title "Tacho ${VERSION}" --notes "$NOTES" \
        dist/Tacho.dmg dist/Tacho.dmg.sha256
    echo "==> Released ${TAG}"
else
    echo
    echo "==> Tag ${TAG} pushed. Create the release on GitHub and attach BOTH files:"
    echo "    https://github.com/${REPO}/releases/new?tag=${TAG}"
    echo "    dist/Tacho.dmg"
    echo "    dist/Tacho.dmg.sha256"
fi
