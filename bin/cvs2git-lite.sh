#!/bin/bash

# Copyright (C) 2014 Craig Phillips.  All rights reserved.

cvs2git_lite_sh=$(readlink -f "$BASH_SOURCE")
cvs2git_lite_pid=$BASHPID

export LDAP_SEARCH_FILTER=${LDAP_SEARCH_FILTER:-'(|(sAMAccountName=$1))'}
export CVS_MAX_CONNECTIONS=${CVS_MAX_CONNECTIONS:-8}

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

Issues:
    If you get cvs errors, it might be due to concurrent connections.  Set
    the environment variable CVS_MAX_CONNECTIONS to something less than the
    default: $CVS_MAX_CONNECTIONS.

Notes:
    This will run a lot faster if you create a local copy of the remote CVS
    repository before hand.

Future:
    I may provide additional branch tracking features.  This will involve
    calculating the git revision or commit checksum that a branch was taken from
    and subsequently merging branch commits onto that branch.

Options:
    -b --branch <TAG>         Branch or tag label (default: HEAD)

    -d --cvsroot              Specify CVSROOT (default: \$CVSROOT)

    -n --dry-run              Don't change the git repository.

    -r --resume <GITCOMMIT>   Resume from a previous script run.  Provide the
                              git commit of the last successful CVS merge.  This
                              can be any number of characters of the sha1sum,
                              but must not be ambiguous.

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
    
    --progress                Output progress instead of verbose output.

Copyright (C) 2014 Craig Phillips.  All rights reserved.
USAGE
}

exec 3>&1 4>&2

function info_s() {
    printf >&3 "%s" "$*"
}

function info_r() {
    printf >&3 "\r%80s\r%s" " " "$*"
}

function info() {
    printf >&3 "%s\n" "$*"
}

function info_progress() {
    [[ $progress ]] || return 0

    if [[ ${1:-} == "end" ]] ; then
        printf "\n" >&5
        exec 3>&5 5>&1
        return 0
    fi

    (( progress_ptr++ )) || true

    local pc=$(( ( $progress_ptr * 100 ) / $progress_max )) \
          cols=40 \
          p= s=

    if (( pc > 0 )) ; then
        p=$(( ( $pc * $cols ) / 100 ))
        s=$(printf "%${p}s" " ")
    fi

    if [[ $resume && $resume_hash ]] ; then
        printf >&5 "\r Skipping: [%-${cols}s] %3s %%" "${s//?/#}" "$pc"
    else
        printf >&5 "\rImporting: [%-${cols}s] %3s %%" "${s//?/#}" "$pc"
    fi
}

function warn() {
    printf >&4 "%s: %s\n" "${cvs2git_lite_sh##*/}" "$*"
}

function err() {
    warn "$*"
    if [[ $BASHPID == $cvs2git_lite_pid && -s $gitdir/cvs2git-lite.log ]] ; then
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

    eval "filter=\"$filter\""

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
            a=$($author_tx "$1") && [[ "$a" ]] ||
                err "Author transform failed, try running kinit"

            author_tx_map[$1]="$a"
        fi

        printf "%s\n" "$a"
    fi
}

# This is to provide a similar implementation to co -p, but this implementation
# ensures that the file permissions are retained.
function cvs_co() {
    (( $# == 3 )) || err "Invalid checkout request: $*"

    if [[ $cvslocal ]] ; then
        local attic_ref=

        if [[ $2 == *"/"* ]] ; then
            mkdir -p "$3/${2%/*}"
            attic_ref="$CVSROOT/$cvsdir/${2%/*}/Attic/${2##*/},v"
        else
            attic_ref="$CVSROOT/$cvsdir/Attic/$2,v"
        fi

        cvs -q co -r$1 -p "$cvsdir/$2" >"$3/$2"

        if [[ -f "$CVSROOT/$cvsdir/$2,v" ]] ; then
            chmod --reference="$CVSROOT/$cvsdir/$2,v" "$3/$2"
        else
            chmod --reference="$attic_ref" "$3/$2"
        fi
        chmod ug+w "$3/$2"
    else
        local cvstmp=$cvstmp/$BASHPID

        rm -rf $cvstmp
        mkdir -p $cvstmp
        (
            cd $cvstmp &&
            cvs -q co -r$1 "$cvsdir/$2"
        )
        rsync --exclude=CVS -a $cvstmp/$cvsdir/ $3/
    fi
}

function git_commit() {
    local $LOG_VARS \
          author= \
          date= \
          comment= \
          pid= \
          pids=() \
          wait_pids=0 \
          gf= \
          commit= \
          unstaged=()

    info "Generating git commit..."
    rm -rf $cvstmp
    mkdir -p $cvstmp

    while IFS=';' read $LOG_VARS ; do
        gf=$gitdir/$f

        (( gcommit_changes++ )) || true

        if [[ ! $comment ]] ; then
            comment=$c
            date=$d
            author=$(author_tx "$a")

            info " * author: $author (cvs: $a)"
            info " * date: $date"
            info " * comment: ${comment:0:60}..."
            commit=1
        fi

        if [[ $s == "dead" ]] ; then
            info " * removing: $gf"
            info " * staging: $gf"
            git rm "$gf"
        else
            info " * fetching: $cvsdir/$f"
            info "   ** revision: $r"
            (
                exec 1>$cvstmp/$BASHPID.out 2>&1
                set -eux +E

                trap - ERR

                cvs_co $r "$f" "$gitdir" 

                touch $cvstmp/$BASHPID.ok
            ) &
            pids+=( $! )
            unstaged+=( "$gf" )
            (( wait_pids++ )) || true

            if (( wait_pids > CVS_MAX_CONNECTIONS )) ; then
                info " * waiting for CVS processes..."
                wait
                wait_pids=0
            fi
        fi
    done

    if (( wait_pids > 0 )) ; then
        info " * waiting for CVS processes..."
        wait
    fi

    if [[ ${pids:-} ]] ; then
        for pid in "${pids[@]}" ; do
            cat $cvstmp/$pid.out
            if [[ ! -e $cvstmp/$pid.ok ]] ; then
                err "Process $pid failed"
            fi
        done
    fi

    if [[ ${unstaged:-} ]] ; then
        for gf in "${unstaged[@]}" ; do
            info " * staging: $gf"
            git add $dry_run "$gf"
        done
    fi

    if [[ $commit ]] ; then
        info " * committing files..."
        git commit $dry_run \
            --author="$author" \
            --date="$date" \
            -m "$comment"

        (( gcommit_count++ )) || true
    else
        info " * nothing to commit"
    fi
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
            f = gensub(/\<Attic\//, "", "", f);
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

function commit_hash() {
    sha1sum <<<"$*" | cut -c -16
}

dry_run=
author_tx=
branch=HEAD
resume=
progress=

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
    (--progress)
        progress=1
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
    (-r|--resume)
        resume=$2
        shift
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
    cvslocal=1
else
    export CVSROOT_DIR=/${CVSROOT#*/}
    cvslocal=
fi

cd $gitdir || err "Failed to change directory: $gitdir"

if [[ ! $resume && $(git status -s $gitdir) ]] ; then
    warn "Git repository needs to be reset and garbage collected, where"
    warn "<GITCOMMIT> is the commit ref to reset back to"
    warn "  git log $gitdir"
    warn "  git reset --hard <GITCOMMIT> $gitdir"
    warn "  git reflog expire --expire-unreachable=now --all $gitdir"
    warn "  git gc --prune=now $gitdir"
    warn "If you are resuming from a previous import, specify"
    warn "  --resume <GITCOMMIT>"
    err "to resume."
fi

TMPDIR=$(mktemp -d) || err "Failed to create work directory"
trap "wait ; rm -rf $TMPDIR" EXIT
trap "warn ; warn 'Interrupt'; trap - ERR ; exit 1" INT
export TMPDIR

cvstmp=$TMPDIR/cvs
mkdir -p $cvstmp

set -Eeu
set -o pipefail
trap 'err "Unhandled error"' ERR

if [[ ${DEBUG:-0} == 1 ]] ; then
    BASH_XTRACEFD=2
    exec 1>$gitdir/cvs2git-lite.log 2>&1 5>/dev/null
    set -x
else
    exec 1>/dev/null 2>&1 5>&1
fi

resume_hash=

if [[ $resume ]] ; then
    info "Locating resume point..."
    git log --pretty="format:%at %s %b%n" \
        "$resume^..$resume" "$gitdir" >$TMPDIR/resume

    while read ts message ; do
        if [[ $resume_hash ]] ; then
            err "Ambiguous commit: $resume"
        fi

        resume_hash=$(commit_hash "$(date -d @$ts +%Y-%m-%dT%H:%M:%S)$message")

        [[ $resume_hash ]] || err "Failed to generate commit hash"
    done < $TMPDIR/resume

    [[ $resume_hash ]] || err "Failed locate resume point: $resume"

    info " * resume hash: $resume_hash"
fi

# RLog impl
info "Generating flat CVS log..."
flog=$TMPDIR/flog
cvs -q rlog -N -r::$branch $cvsdir | flatten_log | sort_flog >$flog

if [[ $progress ]] ; then
    info "Calculating progess..."
    progress_max=$(wc -l <$flog)
    progress_ptr=0
    exec 5>&3 3>&1
fi

last_chash=
gcommit=$TMPDIR/gcommit
>$gcommit

gcommit_count=0
gcommit_changes=0

LOG_VARS="f r d a s l c"
LOG_VAR_LAST=${LOG_VARS##* }

if [[ $resume_hash ]] ; then
    info "Fast forwarding to resume hash"
    info_s ""
fi

# Read ahead for timestamp checking.  Identical timestamps  and comments will be
# merged into the same git repository commmit.
while IFS=';' read $LOG_VARS ; do
    chash=$(commit_hash "$d$c")
    
    info_progress

    if [[ $resume_hash ]] ; then
        if [[ $resume_hash == $last_chash && $resume_hash != $chash ]] ; then
            info_r " * resume from:" ; info ""
            info "   ** date: $d"
            info "   ** message: ${c:0:60}..."
            resume_hash=
        else
            info_r " * $chash"
            last_chash=$chash
            continue
        fi
    fi

    if [[ -s $gcommit && $last_chash && $last_chash != $chash ]] ; then
        git_commit <$gcommit
        >$gcommit
    fi
    last_chash=$chash

    for v in $LOG_VARS ; do
        printf "%s" "${!v}"

        if [[ $v == $LOG_VAR_LAST ]] ; then
            printf "\n"
        else
            printf ";"
        fi
    done >>$gcommit
done < $flog

if [[ -s $gcommit ]] ; then
    git_commit <$gcommit
fi

info_progress "end"

if [[ $resume_hash ]] ; then
    info
    info "Repositories are already in sync"
    exit 0
fi

info "Repositories synchronised:"
info " * commits: $gcommit_count"
info " * changes: $gcommit_changes"
