#!/bin/bash

# Copyright (C) 2015 Craig Phillips.  All rights reserved.

set -eu

setup_sh=$(readlink -f "$BASH_SOURCE")

exec 3>&1

function usage() {
    cat <<USAGE
Usage: ${setup_sh##*/} [options]
Summary:
    Run this utility to setup your home directory with the appropriate
    symbolic links, files and directories for full utilisation of the
    tools provided by this tools suite.

Options:
    -q --quiet         Don't tell me what's happening.
    -f --force         Overwrite existing files.

Setup options:
    -a --setup-all     Run all setup functions.
       --setup-vim     Run the vim setup.
USAGE
}

function err() {
    echo >&2 "${setup_sh##*/}: $*"
    exit 1
}

function setup_vim() {
    if [[ -e $HOME/.vim || -e $HOME/.vimrc ]] ; then
        (( force )) || err "Vim already configured"
    fi

    rm -rf $HOME/.vim $HOME/.vimrc

    mkdir -p $HOME/.vim/autoload $HOME/.vim/bundle
    wget -O $HOME/.vim/autoload/pathogen.vim \
        "https://tpo.pe/pathogen.vim"

    cat - ${setup_sh%/*}/etc/vimrc >$HOME/.vimrc <<VIMRC
execute pathogen#infect()
syntax on
filetype plugin indent on

VIMRC

    git clone git://github.com/tpope/vim-sensible.git \
        $HOME/.vim/bundle/vim-sensible

    git clone git@github.com:itchyny/lightline.vim.git \
        $HOME/.vim/bundle/lightline.vim

    git clone git@github.com:vim-scripts/minibufexplorerpp.git \
        $HOME/.vim/bundle/minibufexplorerpp

    git clone git@github.com:w0ng/vim-hybrid.git \
        $HOME/.vim/bundle/vim-hybrid
}

function setup_bash() {
    err "Not yet implemented"
}

force=0
all=
run=
run_all="setup_vim setup_bash"

while (( $# > 0 )) ; do
    case $1 in
    (-\?|--help) usage ; exit 0 ;;

    (-q|--quiet) exec 1>/dev/null ;;
    (-f|--force) force=1 ;;

    (-a|--setup-all) all=1 ;;
    (--setup-vim) run+=" setup_vim" ;;

    (-*) err "Invalid option: $1" ;;
    (*) err "Invalid argument: $1" ;;
    esac
    shift
done

for fn in ${run:-${all:+$run_all}} ; do
    if [[ ! ${!fn:-} ]] ; then
        echo "Running $fn..."
        $fn ; eval $fn=1
        echo "Completed $fn"
    fi
done

echo "Done"
