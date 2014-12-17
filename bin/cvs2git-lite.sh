#!/bin/bash

# Copyright (C) 2014 Craig Phillips.  All rights reserved.

cvs2git_lite_sh=$(readlink -f "$BASH_SOURCE")

function usage() {
    cat <<USAGE
Usage: ${cvs2git_lite_sh##*/} [options] <CVSDIR> <GITDIR>
Summary:
    This is a light implementation of cvs2git.  The goal of this script is to
    provide a simple way to import a single branch from a CVS repository, into
    a git repository.  The branch of the git repository is assumed to be
    master, but it is not limited to this.  If you checkout a different branch
    in the git repository before you run this tool, it will blindly commit
    changes to that branch.

    The script operates on the remote log, generated from the base of the
    specified directory.  This means that the caller can control what gets
    included in each import.  Branches are not mapped or tracked, so this is
    something you will need to do manually, by first importing HEAD and then
    branching from head at the appropriate commit.  However, the intention here
    is to provide some basic simplified CVS importing, which works around
    problems with importing large and ancient CVS repositories.

Future:
    I may provide additional branch tracking features.  This will involve
    calculating the git revision or commit checksum that a branch was taken from
    and subsequently merging branch commits onto that branch.

Options:
    -b --branch <TAG>         Branch or tag label (default: HEAD)
    -d --cvsroot              Specify CVSROOT (default: \$CVSROOT)
    -n --dry-run              Don't change the git repository.
       --author-tx <CMD>      Call command <CMD> to obtain a tansformed author
                              for each commit.  This is used for instances
                              where CVS authors require mapping to git authors
                              if they are different.  Also can be used to
                              transform usernames into email addresses.

                              The <CMD> is a script that accepts the author
                              as a parameter and returns the transformed author
                              on stdout.

                              There is a built-in LDAP transform, which can be
                              used by specifying 'author_tx_ldap'.  You will
                              need a valid ticket, which you can obtain by
                              running 'kinit' and providing your LDAP password.
                              Setting LDAP_SEARCH_FILTER will override the
                              default filter: $LDAP_SEARCH_FILTER.

Copyright (C) 2014 Craig Phillips.  All rights reserved.
USAGE
}

exec 3>&1 4>&2

function info() {
    printf >&3 "%s\n" "$*"
}

function warn() {
    printf >&4 "%s: %s\n" "${cvs2git_lite_sh##*/}" "$*"
}

function err() {
    warn "$*"
    if [[ -s $gitdir/cvs2git-lite.log ]] ; then
        warn "For details, see $gitdir/cvs2git-lite.log"
    fi
    exit 1
}

function require_dir() {
    if [[ ! -d $1 ]] ; then
        err "Directory does not exist: $1"
    fi
}

function author_tx_ldap() {
    local name= \
          mail= \
          filter=${LDAP_SEARCH_FILTER} \
          ldaptmp=$TMPDIR/author_tx_ldap.out

    filter=${filter//\$1/$1}

    ldapsearch "$filter" name mail >$ldaptmp

    while IFS=: read key val ; do
        case $key in
        (name) name=${val# } ;;
        (mail) mail=${val# } ;;
        esac

        if [[ $mail && $name ]] ; then
            break
        fi
    done < $ldaptmp

    if [[ $name && $mail ]] ; then
        echo "$name <$mail>"
    fi
}

declare -A author_tx_map=()

function author_tx() {
    if [[ $1 ]] ; then
        local a=${author_tx_map[$1]:-}

        if [[ ! $a ]] ; then
            a=$($author_tx "$1") || err "Author transform failed"
            author_tx_map[$1]="$a"
        fi

        printf "%s\n" "$a"
    fi
}

# This is to provide a similar implementation to co -p, but this implementation
# ensures that the file permissions are retained.
function cvs_co() {
    (( $# == 3 )) || err "Invalid checkout request: $*"

    rm -rf $cvstmp
    mkdir -p $cvstmp
    (
        cd $cvstmp &&
        cvs -q co -r$1 "$cvsdir/$2"
    )
    rsync --exclude=CVS -a $cvstmp/$cvsdir/ $3/
}

function git_commit() {
    local f r d a l c \
          author= \
          date= \
          comment=

    info "Generating git commit..."
    while IFS=';' read f r d a s l c ; do
        if [[ $s == "dead" ]] ; then
            info " * removing: $gitdir/$f..."
            info " * staging: $gitdir/$f..."
            git rm "$gitdir/$f"
        else
            info " * fetching: $cvsdir/$f..."
            cvs_co $r "$f" $gitdir

            info " * staging: $gitdir/$f..."
            git add $dry_run "$gitdir/$f"
        fi

        if [[ ! $comment ]] ; then
            comment=$c
            date=$d
            author=$a
        fi
    done

    if [[ $comment ]] ; then
        info " * committing files..."
        git commit $dry_run \
            --author="$(author_tx "$author")" \
            --date="$date" \
            -m "$comment"
    else
        info " * nothing to commit"
    fi
}

function get_commit_info() {
    author=
    message=
    date=

    local first= \
          last= \
          logtmp=$TMPDIR/get_commit_info.out

    cvs rlog -N -r$1 "$2" >$logtmp

    while read line ; do
        if [[ ! $first ]] ; then
            if [[ $line =~ total\ revisions:\ ([0-9]+)\; ]] ; then
                if [[ $revisions != ${BASH_REMATCH[1]} ]] ; then
                    revisions=${BASH_REMATCH[1]}
                    info "      Found new revisions on the server: $revisions"
                fi
            fi

            if [[ $line == "--------"* ]] ; then
                first=1
            fi
            continue
        fi

        if [[ $last ]] ; then
            if [[ $line == "========"* ]] ; then
                break
            fi
            message+="$line "
        else
            if [[ $line =~ date:\ ([0-9:/ ]+)\; ]] ; then
                date=${BASH_REMATCH[1]}
                date=${date//\//-}
                date=${date/ /T}

                if [[ ! $date =~ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} ]] ; then
                    err "Failed to generate a sensible date: $date"
                fi
            fi

            if [[ $line =~ author:\ ([^\;]+)\; ]] ; then
                author=${BASH_REMATCH[1]}
                last=1
            fi
        fi
    done < $logtmp

    [[ $author && $date && $message ]] ||
        err "Failed to get commit info"

}

function flatten_log() {
    local root_re=$CVSROOT_DIR/$cvsdir
          root_re=${root_re//\//\\\/}

    awk '
        BEGIN {
            buf = -1;
            f = -1;
        }

        function flush_buf() {
            ebuf = buf;
            buf = "";

            if (! ebuf || ebuf == -1) return;

            ebuf = gensub(/^\ */, "", "", ebuf);
            ebuf = gensub(/[\n ]*$/, "", "", ebuf);

            printf("%s\n", gensub(/;\ +/, ";", "g", ebuf));
        }

        /^RCS file:/ {
            f = gensub(/^RCS file:\ *'"$root_re"'\/(.+),v$/, "\\1", "");
        }

        f == -1 { next; }

        /^====/ {
            flush_buf();
            f = -1;
            buf = -1;
            next;
        }

        /^----/ {
            flush_buf();
            next;
        }

        buf == -1 { next; }

        /^revision [0-9.]+/ {
            buf = f ";" gensub(/^revision ([0-9.]+)/, "\\1", "") ";";
            next;
        }

        ! buf { next; }

        /^date:/ {
            tbuf = gensub(/\ *([;:])\ */, "\\1", "g");

            d = gensub(/^date:\ *([^;]+);.*/, "\\1", "", tbuf);
            d = gensub(/[\/]/, "-", "g", d);
            d = gensub(/\ /, "T", "", d);
            d = gensub(/\ /, "", "g", d);

            a = gensub(/^.*;author:\ *([^;]+);.*/, "\\1", "", tbuf);
            s = gensub(/^.*;state:\ *([^;]+);.*/, "\\1", "", tbuf);

            if (tbuf ~ /;lines:/) {
                l = gensub(/^.*lines:\ *([^;]+).*$/, "\\1", "", tbuf);
            } else {
                l = "";
            }

            buf = buf d ";" a ";" s ";" l ";";
            next;
        }

        { buf = buf $0 " "; }
    '
}

function sort_flog() {
    sort -k3,7 -t\;
}

dry_run=
author_tx=
branch=HEAD

export LDAP_SEARCH_FILTER=${LDAP_SEARCH_FILTER:-'(|(sAMAccountName=$1))'}

while (( $# > 0 )) ; do
    case $1 in
    (-\?|--help)
        usage
        exit 0
        ;;
    (--author-tx)
        author_tx="$2"
        shift
        ;;
    (-b|--branch)
        branch=$2
        shift
        ;;
    (-d|--cvsroot)
        export CVSROOT=$2
        shift
        ;;
    (-n|--dry-run)
        dry_run="-n"
        ;;
    (-*)
        err "Invalid option: $1"
        ;;
    (*)
        break
        ;;
    esac
    shift
done

if (( $# != 2 )) ; then
    err "Incorrect number of arguments"
fi

[[ $1 ]] && cvsdir=$1 || err "Missing remote CVS directory"

require_dir $2 && gitdir=$(readlink -f "$2")

if [[ $CVSROOT == "/"* ]] ; then
    export CVSROOT_DIR=$CVSROOT
else
    export CVSROOT_DIR=/${CVSROOT#*/}
fi

cd $gitdir || err "Failed to change directory: $gitdir"

if [[ $(cd $gitdir && git status -s) ]] ; then
    err "Git repository needs to be reset"
fi

TMPDIR=$(mktemp -d) || err "Failed to create work directory"
trap "rm -rf $TMPDIR" EXIT
export TMPDIR

cvstmp=$TMPDIR/cvs
mkdir -p $cvstmp

set -eu
set -o pipefail
trap 'err "Unhandled error"' ERR

BASH_XTRACEFD=2
exec 1>$gitdir/cvs2git-lite.log 2>&1
set -x

# RLog impl
info "Generating flat CVS log..."
flog=$TMPDIR/flog
cvs -q rlog -N -r::$branch $cvsdir | flatten_log | sort_flog >$flog

last=
gcommit=$TMPDIR/gcommit
>$gcommit

# Read ahead for timestamp checking.  Identical timestamps  and comments will be
# merged into the same git repository commmit.
while read line ; do
    if [[ $last && $last != $line ]] ; then
        git_commit <$gcommit
        >$gcommit
    fi
    last=$line

    echo "$line" >>$gcommit
done <$flog

if [[ -s $gcommit ]] ; then
    git_commit <$gcommit
fi
