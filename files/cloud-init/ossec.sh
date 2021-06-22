#!/bin/bash

# Setup ossec for monitoring the host. Options for
# /etc/opt/illinois/cloud-init/sss.conf:
#

set -e
ILLINOIS_MODULE=ossec

[[ -e /var/lib/illinois-ossec-init ]] && exit 0
. /etc/opt/illinois/cloud-init/init.sh

[[ -e /etc/opt/illinois/cloud-init/ossec.conf ]] && . /etc/opt/illinois/cloud-init/ossec.conf

illinois_init_status running

# First, add the ossec ipblock sets to iptables
if ! ipset list ossec-blocklist4 &> /dev/null; then
    illinois_log "creating ossec-blocklist4 ipset"
    ipset create ossec-blocklist4 hash:ip family inet

    for chain in INPUT FORWARD; do
        if ! iptables -t filter -C $chain -m set --match-set ossec-blocklist4 src -j REJECT --reject-with icmp-admin-prohibited &> /dev/null; then
            illinois_log "adding ossec-blocklist4 to $chain"
            iptables -t filter -I $chain -m set --match-set ossec-blocklist4 src -j REJECT --reject-with icmp-admin-prohibited
        fi
    done
    /usr/libexec/iptables/iptables.init save
fi

if ! ipset list ossec-blocklist6 &> /dev/null; then
    illinois_log "creating ossec-blocklist6 ipset"
    ipset create ossec-blocklist6 hash:ip family inet6

    for chain in INPUT FORWARD; do
        if ! ip6tables -t filter -C $chain -m set --match-set ossec-blocklist6 src -j REJECT --reject-with icmp6-adm-prohibited &> /dev/null; then
            illinois_log "adding ossec-blocklist6 to $chain"
            ip6tables -t filter -I $chain -m set --match-set ossec-blocklist6 src -j REJECT --reject-with icmp6-adm-prohibited
        fi
    done
    /usr/libexec/iptables/ip6tables.init save
fi

illinois_log "saving ipsets"
/usr/libexec/ipset/ipset.start-stop save


# Next, install ossec
echo "installing ossec"
curl --silent --fail https://updates.atomicorp.com/installers/atomic | sh
illinois_rpm_install ossec-hids ossec-hids-server


# Now, write out an active-response that uses our ipset blocklists
cat > /var/ossec/active-response/bin/illinois-firewall-drop.sh << "EOF"
#!/bin/bash

IPSET="/usr/sbin/ipset"
ARG1=""
ARG2=""
ACTION=$1
USER=$2
IP=$3

LOCAL=`dirname $0`;
cd $LOCAL
cd ../
filename=$(basename "$0")

LOG_FILE="${PWD}/../logs/active-responses.log"

echo "`date` $0 $1 $2 $3 $4 $5" >> ${LOG_FILE}


# Checking for an IP
if [[ -z $IP ]]; then
   echo "$0: <action> <username> <ip>"
   exit 1;
fi

case "${IP}" in
    *:* ) ARG2="ossec-blocklist6" ;;
    *.* ) ARG2="ossec-blocklist4" ;;
    * ) echo "`date` Unable to run active response (invalid IP: '${IP}')." >> ${LOG_FILE} && exit 1 ;;
esac

case "$ACTION" in
    add) ARG1="add" ;;
    delete) ARG1="del" ;;
    *)
        echo "$0: invalid action: ${ACTION}"
        exit 1;
        ;;
esac


if ! $IPSET $ARG1 $ARG2 "$IP" -exist; then
    RES=$?
    echo "`date` Unable to run (ipset returning != $RES): $0 $1 $2 $3 $4 $5" >> ${LOG_FILE}
fi
EOF
chown root:ossec /var/ossec/active-response/bin/illinois-firewall-drop.sh
chmod 0550 /var/ossec/active-response/bin/illinois-firewall-drop.sh

# Write out an ossec.conf file
cat > /var/ossec/etc/ossec-server.conf <<EOF
<ossec_config>
  <global>
    <email_notification>no</email_notification>

    <jsonout_output>yes</jsonout_output>

    <white_list>127.0.0.1/8</white_list>
    <white_list>::1</white_list>
EOF

if [[ -n $ossec_whitelists_path ]]; then
    illinois_log "getting the names of IP whitelists"
    readarray -t ossec_whitelist_names < <(aws ssm describe-parameters \
        --parameter-filters Key=Path,Option=Recursive,Values="$ossec_whitelists_path" \
        --output text --query 'join(`"\n"`, Parameters[].Name)'
    )

    for p in "${ossec_whitelist_names[@]}"; do
        illinois_log "getting whitelist $p"

        readarray -t entries < <(illinois_get_listparam "$p" "")
        echo "    <!-- Parameter Store: $p -->" >> /var/ossec/etc/ossec-server.conf
        for e in "${entries[@]}"; do
            echo "    <white_list>$e</white_list>" >> /var/ossec/etc/ossec-server.conf
        done
    done
fi

cat >> /var/ossec/etc/ossec-server.conf <<EOF
  </global>

  <rules>
    <include>rules_config.xml</include>
    <include>pam_rules.xml</include>
    <include>sshd_rules.xml</include>
    <include>telnetd_rules.xml</include>
    <include>syslog_rules.xml</include>
    <include>arpwatch_rules.xml</include>
    <include>symantec-av_rules.xml</include>
    <include>symantec-ws_rules.xml</include>
    <include>pix_rules.xml</include>
    <include>named_rules.xml</include>
    <include>smbd_rules.xml</include>
    <include>vsftpd_rules.xml</include>
    <include>pure-ftpd_rules.xml</include>
    <include>proftpd_rules.xml</include>
    <include>ms_ftpd_rules.xml</include>
    <include>ftpd_rules.xml</include>
    <include>hordeimp_rules.xml</include>
    <include>roundcube_rules.xml</include>
    <include>wordpress_rules.xml</include>
    <include>cimserver_rules.xml</include>
    <include>vpopmail_rules.xml</include>
    <include>vmpop3d_rules.xml</include>
    <include>courier_rules.xml</include>
    <include>web_rules.xml</include>
    <include>web_appsec_rules.xml</include>
    <include>apache_rules.xml</include>
    <include>nginx_rules.xml</include>
    <include>php_rules.xml</include>
    <include>mysql_rules.xml</include>
    <include>postgresql_rules.xml</include>
    <include>ids_rules.xml</include>
    <include>squid_rules.xml</include>
    <include>firewall_rules.xml</include>
    <include>apparmor_rules.xml</include>
    <include>cisco-ios_rules.xml</include>
    <include>netscreenfw_rules.xml</include>
    <include>sonicwall_rules.xml</include>
    <include>postfix_rules.xml</include>
    <include>sendmail_rules.xml</include>
    <include>imapd_rules.xml</include>
    <include>mailscanner_rules.xml</include>
    <include>dovecot_rules.xml</include>
    <include>ms-exchange_rules.xml</include>
    <include>racoon_rules.xml</include>
    <include>vpn_concentrator_rules.xml</include>
    <include>spamd_rules.xml</include>
    <include>msauth_rules.xml</include>
    <include>mcafee_av_rules.xml</include>
    <include>trend-osce_rules.xml</include>
    <include>ms-se_rules.xml</include>
    <!-- <include>policy_rules.xml</include> -->
    <include>zeus_rules.xml</include>
    <include>solaris_bsm_rules.xml</include>
    <include>vmware_rules.xml</include>
    <include>ms_dhcp_rules.xml</include>
    <include>asterisk_rules.xml</include>
    <include>ossec_rules.xml</include>
    <include>attack_rules.xml</include>
    <include>openbsd_rules.xml</include>
    <include>clam_av_rules.xml</include>
    <include>dropbear_rules.xml</include>
    <include>sysmon_rules.xml</include>
    <include>opensmtpd_rules.xml</include>
    <include>exim_rules.xml</include>
    <include>openbsd-dhcpd_rules.xml</include>
    <include>dnsmasq_rules.xml</include>
    <include>local_rules.xml</include>
  </rules>


  <syscheck>
    <!-- Frequency that syscheck is executed - default to every 22 hours -->
    <frequency>79200</frequency>

    <!-- Directories to check  (perform all possible verifications) -->
    <directories check_all="yes">/etc,/usr/bin,/usr/sbin</directories>
    <directories check_all="yes">/bin,/sbin,/boot</directories>

    <!-- Files/directories to ignore -->
    <ignore>/etc/mtab</ignore>
    <ignore>/etc/mnttab</ignore>
    <ignore>/etc/hosts.deny</ignore>
    <ignore>/etc/mail/statistics</ignore>
    <ignore>/etc/random-seed</ignore>
    <ignore>/etc/adjtime</ignore>
    <ignore>/etc/httpd/logs</ignore>
    <ignore>/etc/utmpx</ignore>
    <ignore>/etc/wtmpx</ignore>
    <ignore>/etc/cups/certs</ignore>
    <ignore>/etc/dumpdates</ignore>
    <ignore>/etc/svc/volatile</ignore>
    <ignore>/etc/sysconfig/ipset</ignore>
  </syscheck>


  <rootcheck>
    <rootkit_files>/var/ossec//etc/shared/rootkit_files.txt</rootkit_files>
    <rootkit_trojans>/var/ossec//etc/shared/rootkit_trojans.txt</rootkit_trojans>
    <system_audit>/var/ossec//etc/shared/system_audit_rcl.txt</system_audit>
    <system_audit>/var/ossec//etc/shared/cis_rhel_linux_rcl.txt</system_audit>
    <system_audit>/var/ossec//etc/shared/cis_rhel5_linux_rcl.txt</system_audit>
  </rootcheck>

  <remote>
    <connection>syslog</connection>
  </remote>
  <remote>
    <connection>secure</connection>
  </remote>
  <alerts>
    <log_alert_level>1</log_alert_level>
    <email_alert_level>7</email_alert_level>
  </alerts>

  <command>
    <name>host-deny</name>
    <executable>host-deny.sh</executable>
    <expect>srcip</expect>
    <timeout_allowed>yes</timeout_allowed>
  </command>
  <command>
    <name>illinois-firewall-drop</name>
    <executable>illinois-firewall-drop.sh</executable>
    <expect>srcip</expect>
    <timeout_allowed>yes</timeout_allowed>
  </command>
  <command>
    <name>disable-account</name>
    <executable>disable-account.sh</executable>
    <expect>user</expect>
    <timeout_allowed>yes</timeout_allowed>
  </command>

  <!-- Active Response Config -->
  <active-response>
    <!-- Firewall Drop response. Block the IP for
       - 600 seconds on the firewall (iptables,
       - ipfilter, etc).
      -->
    <command>illinois-firewall-drop</command>
    <location>local</location>
    <level>6</level>
    <timeout>600</timeout>
    <repeated_offenders>30,60,120</repeated_offenders>
  </active-response>

  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/messages</location>
  </localfile>

  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/secure</location>
  </localfile>

  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/maillog</location>
  </localfile>

  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/cron</location>
  </localfile>
</ossec_config>
EOF

if ! systemctl is-active ossec-hids.service &> /dev/null; then
    illinois_log "enabling and starting ossec"
    systemctl enable ossec-hids
    systemctl start ossec-hids
fi

illinois_init_status finished
date > /var/lib/illinois-ossec-init
