#!/bin/bash

# Copyright (C) 2015 Craig Phillips.  All rights reserved.

varname_from=$1
varname_to=$2
srctree_root=$3

find $srctree_root -type f | \
    xargs sed -i 's?\<'"${varname_from}"'\>?'"${varname_to}"'?g'
