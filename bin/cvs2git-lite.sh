#!/bin/bash

# Copyright (C) 2014 Craig Phillips.  All rights reserved.

cvs2git_lite_sh=$(readlink -f "$BASH_SOURCE")

function usage() {
    cat <<USAGE
Usage: ${cvs2git_lite_sh##*/} [options] <CVSDIR> <GITDIR>
Summary:
    This is a light implementation of cvs2git.  The goal of this script is to
    provide a simple way to import a single checked out branch from CVS, into
    a git repository.  The branch of the git repository is assumed to be
    master, but it is not limited to this.  If you checkout a different branch
    in the git repository before you run this tool, it will blindly commit
    changes to that branch.

    The script operates on a file by file basis, importing all versions of all
    files, one file and one version at a time.  For example, if you have 18
    revisions of /somedir/somefile.c, the script will checkout version 1.1 of
    the file first and iterate over each revision, merging changes with the
    original commit message.  If you have a branch checked out in your CVS
    directory, the file revisions will have a base revision that will not be
    back tracked.  For example, a file might have the revision 1.3.2.14.  This
    indicates the file was branched from trunk at 1.3 and has subsequently been
    branched again at 1.3.2 to 1.3.2.1.  Since then, 13 changes have been made
    to the file.  This script will only merge the 14 revisions on the branch
    copy and will not back track to 1.3.2, 1.3.1, 1.3, 1.2 and 1.1.

    The ultimate goal of this script is to retain change history for a single
    branch on a subset of a CVS repository, without having to import the whole
    repository - which is what cvs2git does.  Use this if you want to import
    some subset of a CVS project and start working on it immediately.

Options:
    -? --help                 Display usage and exit.
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

    if [[ $author_tx ]] ; then
        local a=${author_tx_map[$author]:-}

        if [[ ! $a ]] ; then
            a=$($author_tx "$author") || err "Author transform failed"
            author_tx_map[$author]="$a"
        fi

        author=$a
    fi
}

dry_run=
author_tx=

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

require_dir $1 && cvsdir=$(readlink -f "$1")
require_dir $2 && gitdir=$(readlink -f "$2")

cd $gitdir || err "Failed to change directory: $gitdir"

if [[ $(cd $gitdir && git status -s) ]] ; then
    err "Git repository needs to be reset"
fi

TMPDIR=$(mktemp -d) || err "Failed to create work directory"
trap "rm -rf $TMPDIR" EXIT
export TMPDIR

set -eu
trap 'err "Unhandled error"' ERR

BASH_XTRACEFD=2
set -x
exec 1>$gitdir/cvs2git-lite.log 2>&1

cvs_ent_tmp=$(mktemp)
find $cvsdir -type f -path '*/CVS/Entries' -printf "%P\n" >$cvs_ent_tmp

while read cvs_entries ; do
    cvs_subdir=${cvs_entries%CVS/Entries}
    cvs_subdir=${cvs_subdir%/}

    cvs_repo_path=$cvsdir/$cvs_subdir/CVS/Repository
    cvs_repo=$(cat $cvs_repo_path 2>/dev/null) ||
        err "Failed to obtain CVS repository path from $cvs_repo_path"

    info "Traversing: ${cvs_subdir:-.}"
    while IFS="/" read t path rev x ; do
        [[ $t != "D" ]] || continue
        [[ $path ]] || continue

        base_rev=${rev%.*}
        cvs_file=${cvs_subdir:+$cvs_subdir/}$path
        cvs_repofile=$cvs_repo/$path
        git_file=$gitdir/$cvs_file
        git_subdir=${git_file%/*}

        revisions=${rev##*.}

        info "  Processing: $cvs_file"

        [[ $revisions ]] || err "Failed to determine file revisions"

        info "    Revisions: $revisions"
        for (( i = 1 ; i <= ${rev##*.} ; i++ )) ; do
            co_rev=$base_rev.$i

            info "    Revision: ${base_rev}.$i"
            get_commit_info $co_rev $cvs_repofile

            info "      Commit Info:"
            info "        Author:  $author"
            info "        Date:    $date"
            info "        Message: ${message:0:60}..."

            # Directory initialisation
            if [[ ! -d $git_subdir ]] ; then
                info "      Creating directory: $git_subdir"
                mkdir -p $git_subdir
                git add $dry_run $git_subdir
            fi

            # File initialisation
            info "      Fetching file..."
            cvs co -p -r $co_rev $cvs_repofile >$git_file

            info "      Updating file mode..."
            chmod --reference=$cvsdir/$cvs_file $git_file

            # Record the change in the git repository
            info "      Adding the file to git repository..."
            git add $dry_run $git_file

            info "      Committing the file to the git repository..."
            git commit $dry_run \
                --author="$author" \
                --date="$date" \
                -m "$message" || [[ $dry_run ]]

            info "    Done"
        done
        info "  Done"
    done < $cvsdir/$cvs_entries
    info "Done"
done < $cvs_ent_tmp
