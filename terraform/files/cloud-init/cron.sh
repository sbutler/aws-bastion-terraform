#!/bin/bash

# Setup cron and harden it. Options available in
# /etc/opt/illinois/cloud-init/cron.conf:
#
#   cron_allow_parameter: SSM parameter that contains users allowed to use cron.

set -e
ILLINOIS_MODULE=cron

[[ -e /var/lib/illinois-cis-init ]] && exit 0
. /etc/opt/illinois/cloud-init/init.sh

[[ -e /etc/opt/illinois/cloud-init/cron.conf ]] && . /etc/opt/illinois/cloud-init/cron.conf

if [[ -z $cron_allow_parameter ]]; then
    illinois_log err "no cron_allow_parameter specified"
    exit 1
fi

illinois_init_status running

for file in /etc/crontab; do
    illinois_log "setting access on $file"
    chown root:root "$file"
    chmod 0600 "$file"
done

for d in cron.hourly cron.daily cron.weekly cron.monthly cron.d; do
    illinois_log "setting access on /etc/$d"
    chown root:root "/etc/$d"
    chmod 0700 "/etc/$d"
done

for svc in cron at; do
    if [[ -e /etc/$svc.deny ]]; then
        illinois_log "removing /etc/$svc.deny"
        rm /etc/$svc.deny
    fi

    illinois_log "setting /etc/$svc.allow from $cron_allow_parameter"
    illinois_get_listparam "$cron_allow_parameter" "" > /etc/$svc.allow
    chown root:root /etc/$svc.allow
    chmod 0600 /etc/$svc.allow

    illinois_log "restarting ${svc}d"
    systemctl restart ${svc}d
done

illinois_init_status finished
date > /var/lib/illinois-cron-init
