#!/bin/bash

# Takes URLs and downloads them from S3 to a place where we can read them later
# from cloud-init includes. Options in /etc/opt/illinois/cloud-init/s3-download.conf:
#
#   INCLUDE_URL_BASE: base URL for all the files.
#   PRV_FILES: array of files only accessible by root.
#   PUB_FILES: array of files readable by everyone but only writable by root.

set -e
ILLINOIS_MODULE=s3-download

[[ $ILLINOIS_FORCE =~ ^(n|no|f|false|0)?$ && -e /var/lib/illinois-s3-download-init ]] && exit 0
. /etc/opt/illinois/cloud-init/init.sh

[[ -e /etc/opt/illinois/cloud-init/s3-download.conf ]] || exit 0
. /etc/opt/illinois/cloud-init/s3-download.conf

illinois_init_status running

download_file () {
    f="$1"
    u="${INCLUDE_URL_BASE}${f}"

    illinois_log "downloading $u -> $f"
    aws s3 cp "$u" "$f" || :
}

umask 0077
for file in "${PRV_FILES[@]}"; do
    download_file "$file"
done

umask 0022
for file in "${PUB_FILES[@]}"; do
    download_file "$file"
done

illinois_init_status finished
date > /var/lib/illinois-s3-download-init
