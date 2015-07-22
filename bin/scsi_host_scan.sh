#!/bin/bash

# Copyright (C) 2015 Craig Phillips.  All rights reserved.

for f in /sys/class/scsi_host/host*/scan ; do
    echo "Scanning $f"
    echo " - - -" >$f
done

dmesg | tail -20
