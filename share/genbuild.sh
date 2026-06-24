#!/bin/sh
# Copyright (c) 2012-2016 The Bitcoin Core developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.

if [ $# -gt 1 ]; then
    cd "$2"
fi
if [ $# -gt 0 ]; then
    FILE="$1"
    shift
    if [ -f "$FILE" ]; then
        INFO="$(head -n 1 "$FILE")"
    fi
else
    echo "Usage: $0 <filename> <srcroot>"
    exit 1
fi

DESC=""
SUFFIX=""
# CI passes the pushed tag name via FORCE_BUILD_DESC so the version string is
# correct even where git describe can't resolve the tag -- e.g. the Windows
# MSYS2 job, whose git differs from the native git that actions/checkout used to
# fetch the tags, leaving git describe empty and the build on the commit-suffix
# fallback (which shipped a wrong "-beta" version).
if [ -n "$FORCE_BUILD_DESC" ]; then
    DESC="$FORCE_BUILD_DESC"
elif [ -e "$(which git 2>/dev/null)" -a "$(git rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ]; then
    # clean 'dirty' status of touched files that haven't been modified
    git diff >/dev/null 2>/dev/null 

    # if latest commit is tagged and not dirty, then override using the tag name.
    # Match this fork's lightweight "v*-ROZ" tags (and include --tags so lightweight
    # tags are considered); without it, plain `git describe` only sees the old
    # annotated `v1.0.2.7-beta` tag and leaks "-beta" into the version string.
    RAWDESC=$(git describe --tags --abbrev=0 --match 'v*-ROZ' 2>/dev/null)
    if [ "$(git rev-parse HEAD)" = "$(git rev-list -1 $RAWDESC 2>/dev/null)" ]; then
        git diff-index --quiet HEAD -- && DESC=$RAWDESC
    fi

    # otherwise generate suffix from git, i.e. string like "59887e8-dirty"
    SUFFIX=$(git rev-parse --short HEAD)
    git diff-index --quiet HEAD -- || SUFFIX="$SUFFIX"
fi

if [ -n "$DESC" ]; then
    NEWINFO="#define BUILD_DESC \"$DESC\""
elif [ -n "$SUFFIX" ]; then
    NEWINFO="#define BUILD_SUFFIX $SUFFIX"
else
    NEWINFO="// No build information available"
fi

# only update build.h if necessary
if [ "$INFO" != "$NEWINFO" ]; then
    echo "$NEWINFO" >"$FILE"
fi
