#!/usr/bin/env bash
#
# Copyright (c) 2009-2012 VMware, Inc.

set -e

base_dir=$(readlink -nf $(dirname $0)/../..)
source $base_dir/lib/prelude_apply.bash

# this parameters is used by bosh agent
# we should use vsphere when building for vcloud
infrastructure=$system_parameters_infrastructure
[ "$infrastructure" == "vcloud" ] && infrastructure=vsphere
echo -n $infrastructure > $chroot/etc/infrastructure
