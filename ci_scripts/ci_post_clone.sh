#!/bin/zsh

# Generate CareHive.xcodeproj before Xcode Cloud tries to build anything.
#
# This script exists because of a specific mismatch between how this repository
# is laid out and what Xcode Cloud expects to find when it clones it.
#
# The repository does not commit `.xcodeproj`. `project.yml` is the source of
# truth and the project file is generated from it -- see the note at the top of
# that file, and `.gitignore`, which excludes `*.xcodeproj/` on purpose. On
# GitHub Actions that was handled by a step in the workflow.
#
# Xcode Cloud has no equivalent step. It decides what it can build by running
#
#     xcodebuild -project CareHive.xcodeproj -describeAllArchivableProducts -json
#
# against the clone, so a checkout with no project file in it is not a project
# Xcode Cloud can see, let alone archive. `ci_post_clone.sh` is Apple's hook for
# exactly this: it runs after the clone and before anything is built, and Apple
# documents installing a third-party tool as its intended use.
#
# zsh with a shebang, because Apple documents zsh as the default shell for these
# scripts but also documents the shebang as best practice -- and this file is
# created on Windows, where the executable bit has to be set deliberately (see
# the commit that added it: `git update-index --chmod=+x`).

set -euo pipefail

# Apple runs these scripts with `ci_scripts/` as the working directory, not the
# repository root, so every path below is relative to a directory one level up.
# `dirname "$0"` rather than a hardcoded `..` so the script still works when
# someone runs it by hand from somewhere else.
cd "$(dirname "$0")/.."

echo "ci_post_clone: repository root is $(pwd)"

# Homebrew is part of the Xcode Cloud image (Apple links brew.sh directly from
# the "Making dependencies available" page), but it is not necessarily on PATH
# from this shell -- on Apple silicon it lives in /opt/homebrew and the login
# profile that exports it has not run here. Sourcing it explicitly is one line
# and removes a class of failure that would otherwise look like "brew: command
# not found" in the middle of a build.
if ! command -v brew >/dev/null 2>&1; then
    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
fi

if ! command -v brew >/dev/null 2>&1; then
    echo "ci_post_clone: Homebrew not found; cannot install xcodegen" >&2
    exit 1
fi

# No auto-update: the environment is fresh on every build, so `brew update`
# fetches a repository index nobody will reuse. It is the slowest part of a
# `brew install` and buys nothing here.
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1

echo "ci_post_clone: installing xcodegen"
brew install xcodegen

# XcodeGen reads `minimumXcodeGenVersion: 2.40` out of project.yml and refuses
# to generate against anything older, which is the check that matters here --
# `brew install` resolving to a version below it would otherwise be discovered
# as a confusing parse error further down.
echo "ci_post_clone: xcodegen $(xcodegen --version)"

# A stale directory cannot exist on a fresh clone, but this is cheap and it also
# protects the case where someone reruns the script by hand locally after a
# failed generation -- a half-written .xcodeproj is worse than none, because it
# is the thing Xcode Cloud will then try to describe.
rm -rf CareHive.xcodeproj

xcodegen generate

# Prove the thing Xcode Cloud is about to ask for actually exists. Without this
# the failure surfaces as an empty product list in the build report, which reads
# like a workflow misconfiguration rather than a generation problem.
if [[ ! -d CareHive.xcodeproj ]]; then
    echo "ci_post_clone: xcodegen reported success but CareHive.xcodeproj is missing" >&2
    exit 1
fi

echo "ci_post_clone: generated CareHive.xcodeproj"
