#!/bin/bash

# Copyright (C) 2014 Craig Phillips.  All rights reserved.

git_remote_install_cert_sh=$(readlink -f "$BASH_SOURCE")

function usage() {
    cat <<USAGE
Usage: ${git_remote_install_cert_sh##*/} [<name>]
Summary:
    Installs the SSL certificate of the HTTPS connection defined by the remote
    with the name <name> or 'origin' if omitted.  The certificates are placed
    under ~/.gitcerts/<remote>.crt, where <remote> is the full qualified 
    hostname of the remote URL.

    Global Git configuration is also updated, setting http.sslCAPath to the
    directory ~/.gitcerts, under which the certficate is installed.

Options:
    -v --verbose             Verbose output.

Example:
    ${git_remote_install_cert_sh##*/} origin
USAGE
}

function err() {
    echo >&2 "${git_remote_install_cert_sh##*/}: $*"
    exit 1
}

function get_remote() {
    local name= url= path=

    while read name url x ; do
        if [[ $name == $1 ]] ; then
            echo "$url"
            return 0
        fi
    done < <(git remote -v)

    return 1
}

exec 3>/dev/null

while (( $# > 0 )) ; do
    case $1 in
    (-v|--verbose)
        exec 3>&2
        ;;
    (-\?|--help)
        usage
        exit 0
        ;;
    esac
    shift
done

name=${1:-origin}

url=$(get_remote "$name") ||
    err "Remote '$name' not found"

if [[ $url =~ ^https://([^/]+) ]] ; then
    server=${BASH_REMATCH[1]}
    name=${server%%@*}
    server=${server##*@}

    url=${BASH_REMATCH[0]}/
    url=${url/$name@/}

    [[ $server ]] || err "No match"

    if [[ ! $server =~ :[0-9]+$ ]] ; then
        server+=:443
    fi
else
    err "Remote '$name' url is not HTTPS: $url"
fi

certtmp=$(UMASK=0077 mktemp)
trap "rm -f $certtmp" EXIT

echo "Requesting certificate from the server..."
openssl 2>&3 s_client -connect $server </dev/null | \
    awk >$certtmp '
        BEGIN {
            f = 0;
        } 
        f == 1 || /^-----BEGIN CERTIFICATE-----/ {
            f = 1;
            print;
        }
        /^-----END CERTIFICATE-----/ {
            exit;
        }
    '

if (( $? != 0 )) ; then
    err "Failed to get certificate from: $server"
fi

[[ -s $certtmp ]] || err "Failed to obtain certificate"

cert="$HOME/.gitcerts/${server%:*}.crt"

mkdir -m 0700 -p ${cert%/*} ||
    err "Failed to create Git certificate store"

mv $certtmp $cert ||
    err "Failed to import certificate"

echo "Certificate installed to: $cert"
git config --global http.sslCAPath "$HOME/.gitcerts" ||
    err "Failed to set 'http.sslCAPath' configuration setting"
