#!/usr/bin/env bash

# Copyright (C) 2015 Craig Phillips.  All rights reserved.

set -eu

setup_sh=$(readlink -f "$BASH_SOURCE")

exec 3>&1

unset -f $(declare -F | awk '{ print $NF }')

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
       --setup-bash    Run the bash setup.
       --setup-screen  Run the screen setup.
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

    install -vm 0640 ${setup_sh%/*}/etc/vimrc $HOME/.vimrc

    git clone git://github.com/tpope/vim-sensible.git \
        $HOME/.vim/bundle/vim-sensible

    git clone git@github.com:itchyny/lightline.vim.git \
        $HOME/.vim/bundle/lightline.vim

    git clone git@github.com:vim-scripts/minibufexplorerpp.git \
        $HOME/.vim/bundle/minibufexplorerpp

    git clone git@github.com:w0ng/vim-hybrid.git \
        $HOME/.vim/bundle/vim-hybrid

    git clone https://github.com/scrooloose/syntastic.git \
        $HOME/.vim/bundle/syntastic
}

function setup_bash() {
    if [[ -e $HOME/.bashrc ]] ; then
        (( force )) || err "File $HOME/.bashrc is in the way"
    fi

    if [[ -L $HOME/.bashrc ]] ; then
        (( force )) || err "Bash is already configured"
    fi

    rm -f $HOME/.bashrc
    ln -s ${setup_sh%/*}/bash/bashrc $HOME/.bashrc
}

function setup_screen() {
    if [[ -e $HOME/.screenrc ]] ; then
        (( force )) || err "File $HOME/.screenrc is in the way"
    fi

    if [[ -L $HOME/.screenrc ]] ; then
        (( force )) || err "Screen is already configured"
    fi

    rm -f $HOME/.screenrc
    ln -s ${setup_sh%/*}/etc/screenrc $HOME/.screenrc
}

force=0
all=
run=
run_all=$(declare -F | awk '/^declare -f setup_/ { print $NF }')
run_exec=

while (( $# > 0 )) ; do
    case $1 in
    (-\?|--help) usage ; exit 0 ;;

    (-q|--quiet) exec 1>/dev/null ;;
    (-f|--force) force=1 ;;

    (-a|--setup-all) all=1 ;;
    (--setup-vim) run+=" setup_vim" ;;
    (--setup-bash) run+=" setup_bash" ;;
    (--setup-screen) run+=" setup_screen" ;;

    (-*) err "Invalid option: $1" ;;
    (*) err "Invalid argument: $1" ;;
    esac
    shift
done

for fn in ${run:-${all:+$run_all}} ; do
    if [[ ! ${!fn:-} ]] ; then
        echo "Running $fn..."
        $fn ; eval $fn=1
        run_exec+=" $fn"
        echo "Completed $fn"
    fi
done

if [[ $run_exec ]] ; then
    echo "Done"
else
    err "Nothing to do"
fi
