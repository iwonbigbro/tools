#!/bin/bash

# Copyright (C) 2014 Craig Phillips. All rights reserved.

git_mtime_fix=$(readlink -f "$BASH_SOURCE")

function usage() {
    cat <<USAGE
Usage: ${git_mtime_fix%/*} [options]
Summary:
    When Jenkins Git-Plugin checks out files from a Git repository after pulling
    changes, it has the side effect of updating the file modification timestamps
    such that they are all the current system time.  This affects how GNU make
    is then able to resolve dependencies.

    This script runs over each file known to the Git repository and sets the
    modification time to the author commit time of each file.

Options:
    -C --chdir <PATH>          Change directory before running.
    -v --verbose               Set verbose output.
USAGE
}

function err() {
    echo >&2 "${git_mtime_fix%/*}: $*"
    exit 1
}

function git_mtime() {
    local sha1
    sha1=$(git rev-list --max-count=1 HEAD "$1") &&
    git show --pretty=format:%at --abbrev-commit $sha1 | head -1
}

exec 5>/dev/null

while (( $# > 0 )) ; do
    case $1 in
    (-\?|--help)
        usage
        exit 0
        ;;
    (-C|--chdir)
        cd "$2"
        shift
        ;;
    (-v|--verbose)
        exec 5>&2
        ;;
    (*) err "Invalid argument: $1" ;;
    esac
    shift
done

git ls-files | while read f ; do
    printf >&5 "%2s  %s" " -" "$f"

    if [[ -f "$f" ]] ; then
        stat=$(git status -s "$f" | cut -c -2)

        if [[ ! $stat ]] ; then
            git_mtime=$(git_mtime "$f") &&

            if [[ $git_mtime ]] ; then
                loc_mtime=$(stat -c %Y "$f") || loc_time=0

                if (( git_mtime == loc_mtime )) ; then
                    printf >&5 "\033[2K\r"
                    continue
                else
                    touch -m -d "$(date -d @$git_mtime)" "$f" &&
                    if (( git_mtime > loc_mtime )) ; then
                        stat=" T"
                    else
                        stat=" t"
                    fi
                fi
            fi
        fi
    else
        stat=" D"
    fi

    printf >&5 "\r%2s  %s\n" "${stat:-ER}" "$f"
done
