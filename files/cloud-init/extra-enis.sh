#cloud-boothook

# Installs various networking scripts so that added interfaces get the proper
# configuration. Note: this does not actually create and attach the ENIs, it is
# expected a Lambda will do that. Options available in
# /etc/opt/illinois/cloud-init/extra-enis.conf:
#
#   extra_enis_prefix_list_ids: associative array where each key is the name of
#       an interface (eth1, eth2, etc) and the value is a space deliminated
#       list of prefix-id's to add routes for over that interface.

set -e
ILLINOIS_MODULE=extra-enis

[[ -e /var/lib/illinois-extra-enis-init ]] && exit 0
. /etc/opt/illinois/cloud-init/init.sh

illinois_init_status running

for d in /etc/sysconfig/network-scripts /etc/dhcp/dhclient.d /usr/local/bin /etc/udev/rules.d /usr/local/lib/systemd/system; do
  [[ -e $d ]] || mkdir -p "$d"
done

if [[ ! -e /etc/sysconfig/network-scripts/illinoisnet-functions ]]; then
    cat > /etc/sysconfig/network-scripts/illinoisnet-functions <<"HERE"
# -*-Shell-script-*-

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the MIT License. See the LICENSE accompanying this file
# for the specific language governing permissions and limitations under
# the License.

# This file is not a stand-alone shell script; it provides functions
# to ec2 network scripts that source it.

# Copied from https://github.com/aws/amazon-ec2-net-utils

# Set up a default search path.
PATH="/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin"
export PATH

# metadata query requires an interface and hardware address
if [[ -z "${INTERFACE}" ]]; then
  exit
fi

# Support alternate locations for config files in order to facilitate
# testing.
ETCDIR=${ETCDIR:-/etc}
SYSFSDIR=${SYSFSDIR:-/sys}

HWADDR=$(cat "${SYSFSDIR}/class/net/${INTERFACE}/address" 2>/dev/null)
while [[ $HWADDR = "00:00:00:00:00:00" ]]; do
  sleep 0.1
  HWADDR=$(cat "${SYSFSDIR}/class/net/${INTERFACE}/address" 2>/dev/null)
done
if [[ -z $HWADDR && $ACTION != "remove" ]]; then
  exit
fi
export HWADDR

# generate a routing table number
RTABLE=${INTERFACE#eth}
let RTABLE+=10000

METADATA_BASEURL="http://169.254.169.254/latest"
METADATA_MAC_PATH="meta-data/network/interfaces/macs"
METADATA_TOKEN_PATH="api/token"

config_file="$ETCDIR/sysconfig/network-scripts/ifcfg-${INTERFACE}"
route_file="$ETCDIR/sysconfig/network-scripts/route-${INTERFACE}"
route6_file="$ETCDIR/sysconfig/network-scripts/route6-${INTERFACE}"
dhclient_file="$ETCDIR/dhcp/dhclient-${INTERFACE}.conf"
extraconfig_file="$ETCDIR/opt/illinois/cloud-init/extra-enis.conf"

ip () { command "$FUNCNAME" $@; }
ifup () { command "$FUNCNAME" $@; }
ifdown () { command "$FUNCNAME" $@; }
logger () { command "$FUNCNAME" --tag illinoisnet $@; }
rm () { command "$FUNCNAME" $@; }

get_meta() {
  logger "[get_meta] Querying IMDS for ${METADATA_MAC_PATH}/${HWADDR}/${1}"
  logger "[get_meta] Getting token for IMDSv2."

  # IMDS may have become temporarily unreachable, retry
  max_attempts=60
  attempts=${max_attempts}
  imds_exitcode=1
  while (( imds_exitcode > 0 )); do
    if (( attempts == 0 )); then
      logger "[get_meta] Failed to get IMDSv2 metadata token after ${max_attempts} attempts... Aborting"
      return $imds_exitcode
    fi

    imds_token=$(curl -s -f -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" ${METADATA_BASEURL}/${METADATA_TOKEN_PATH})
    imds_exitcode=$?
    if (( imds_exitcode > 0 )); then
      let attempts--
      sleep 0.5
    fi
  done

  # IMDS can take up to 30s to provide the information of a new ENI
  attempts=${max_attempts}
  imds_exitcode=1
  while (( imds_exitcode > 0 )); do
    if (( attempts == 0 )); then
      logger "[get_meta] Failed to get ${METADATA_BASEURL}/${METADATA_MAC_PATH}/${HWADDR}/${1}"
      return $imds_exitcode
    fi
    logger "[get_meta] Trying to get ${METADATA_BASEURL}/${METADATA_MAC_PATH}/${HWADDR}/${1}"
    meta=$(curl -s -H "X-aws-ec2-metadata-token: ${imds_token}" -f ${METADATA_BASEURL}/${METADATA_MAC_PATH}/${HWADDR}/${1})
    imds_exitcode=$?
    # Temporary hack to avoid retries on prefix delegation keys that don't actually exist yet:
    if [[ $1 = *-prefix ]]; then
        break
    elif (( imds_exitcode > 0 )); then
      let attempts--
      sleep 0.5
    fi
  done

  echo "${meta}"
  return $imds_exitcode
}

get_cidr() { get_meta 'subnet-ipv4-cidr-block'; }
get_ipv4s() { get_meta 'local-ipv4s'; }

get_primary_ipv4() {
  ipv4s=($(get_ipv4s))
  ec=$?
  [[ $ec -eq 0 ]] && echo "${ipv4s[0]}"
  return $ec
}

get_secondary_ipv4s() {
  ipv4s=($(get_ipv4s))
  ec=$?
  [[ $ec -eq 0 ]] && echo "${ipv4s[@]:1}"
  return $ec
}

get_delegated_prefix() { get_meta "${1}-prefix"; }

get_ipv6s() {
  ip -6 addr list dev ${INTERFACE} scope global \
      | grep "inet6" \
      | awk '{print $2}' | cut -d/ -f1
}

get_ipv6_gateway() {
  # Because we start dhclient -6 immediately on interface
  # hotplug, it's possible we get a DHCP response before we
  # receive a router advertisement. The only immediate clue we
  # have about the gateway is the MAC address embedded in the
  # DHCP6 server ID. If that env var is passed to dhclient-script
  # we determine the router address from that; otherwise we wait
  # up to 10 seconds for an RA route to be added by the kernel.

  if [[ $new_dhcp6_server_id  =~ ^0:3:0:1: ]]; then
    logger "[get_ipv6_gateway] Using DHCP6 environment variable"
    octets=($(echo "$new_dhcp6_server_id" | rev | cut -d : -f -6 | rev | tr : ' '))

    # The gateway's link local address is derived from the
    # hardware address by converting the MAC-48 to an EUI-64:
    #   00:00:5e  :  00:53:35
    #   ^^      ^^^^^ ff:fe is inserted in the middle
    #   first octet is xored with 0x2 (second LSB is flipped)
    # thus 02:00:5e:ff:fe:00:53:35.
    #
    # The EUI-64 is used as the last 64 bits in an fe80::/64
    # address, so fe80::200:5eff:fe00:5335.

    declare -A quibbles # quad nibbles
    quibbles[0]=$(( ((0x${octets[0]} ^ 2) << 8) + 0x${octets[1]} ))
    quibbles[1]=$(( 0x${octets[2]}ff ))
    quibbles[2]=$(( 0xfe00 + 0x${octets[3]} ))
    quibbles[3]=$(( (0x${octets[4]} << 8) + 0x${octets[5]} ))
    printf "fe80::%04x:%04x:%04x:%04x\n" ${quibbles[@]}
  else
    logger "[get_ipv6_gateway] Waiting for IPv6 router advertisement"
    attempts=20
    while :; do
      if (( attempts == 0 )); then
        logger "[get_ipv6_gateway] Failed to receive router advertisement"
        return
      fi

      gateway6=$(ip -6 route show dev "${INTERFACE}" | grep ^default | awk '{print $3}')
      if [[ -n $gateway6 ]]; then
        break
      else
        let attempts--
        sleep 0.5
      fi
    done
    echo "${gateway6}"
  fi
}

rewrite_primary() {
  logger "[rewrite_primary] Rewriting configs for ${INTERFACE}"
  cidr=$(get_cidr)
  if [[ $? -ne 0 ]]; then
    # For any errors from IMDS, bail out early rather than rewriting anything
    # We'll get back here later and be able to rewrite things.
    logger "[rewrite_primary] Error $? contacting IMDS for ${INTERFACE}. Bailing out."
    return $?
  elif [[ -z $cidr ]]; then
    return
  fi

  network=$(echo ${cidr}|cut -d/ -f1)
  router=$(( $(echo ${network}|cut -d. -f4) + 1))
  gateway="$(echo ${network}|cut -d. -f1-3).${router}"
  primary_ipv4="$(get_primary_ipv4)"

  if [[ $INTERFACE = "eth0" ]]; then
    if [[ -e $route_file ]]; then
      sed -re '/^### BEGIN illinoisnet primary/,/### END illinoisnet primary/d' "${route_file}" > "${route_file}.illinois-tmp"
    fi
    cat <<EOF >> "${route_file}.illinois-tmp"
### BEGIN illinoisnet primary
default via ${gateway} dev ${INTERFACE} table ${RTABLE}
${cidr} dev ${INTERFACE} proto kernel scope link src ${primary_ipv4} table ${RTABLE}
169.254.169.254 via 0.0.0.0 dev ${INTERFACE} table ${RTABLE}
### END illinoisnet primary
EOF
    mv "${route_file}.illinois-tmp" "${route_file}"

    # Also, interface is already up when we run, so add the routes manually
    ip -4 route add default via ${gateway} dev ${INTERFACE} table ${RTABLE}
    ip -4 route add ${cidr} dev ${INTERFACE} proto kernel scope link src ${primary_ipv4} table ${RTABLE}
    ip -4 route add 169.254.169.254 via 0.0.0.0 dev ${INTERFACE} table ${RTABLE}
  fi

  # Wait 30sec until the other scripts have loaded the basic routes, so that
  # we know this is done and we can make our changes
  local load_maxtry=60
  while (( load_maxtry > 0 )); do
    if [[ $(ip -4 route show table $RTABLE | wc -l) -ge 2 ]]; then
      break
    fi

    (( load_maxtry-- )) || :
    if (( load_maxtry > 0 )); then
      logger "[rewrite_primary] waiting for ec2net to load its routes"
      sleep 0.5
    fi
  done

  if [[ -e $extraconfig_file ]]; then
    . "${extraconfig_file}"

    if [[ -n ${extra_enis_prefix_list_ids[$INTERFACE]} ]]; then
      if [[ -e $route_file ]]; then
        sed -re '/^### BEGIN illinoisnet routes/,/### END illinoisnet routes/d' "${route_file}" > "${route_file}.illinois-tmp"
      fi
      echo '### BEGIN illinoisnet routes' >> "${route_file}.illinois-tmp"

      for pl in ${extra_enis_prefix_list_ids[$INTERFACE]}; do
        logger "[rewrite_primary] Adding prefix-list routes ($pl) for ${INTERFACE}"
        for prefix_cidr in $(aws ec2 get-managed-prefix-list-entries \
            --prefix-list-id $pl \
            --output text \
            --query 'join(`" "`, Entries[].Cidr)'); do
          logger "[rewrite_primary] Adding route ${prefix_cidr} via ${gateway} for ${INTERFACE}"
          echo "${prefix_cidr} via ${gateway} dev ${INTERFACE} metric ${RTABLE}" >> "${route_file}.illinois-tmp"
          ip -4 route add ${prefix_cidr} via ${gateway} dev ${INTERFACE} metric ${RTABLE}
        done
      done

      echo '### END illinoisnet prefix-list' >> "${route_file}.illinois-tmp"
      mv "${route_file}.illinois-tmp" "${route_file}"
    fi
  fi
}

remove_rules() {
  logger "[remove_rules] Removing rules for ${INTERFACE}"
  for rule in $(ip -4 rule list \
                |grep "from .* lookup ${RTABLE}" \
                |awk -F: '{print $1}'); do
    ip -4 rule delete pref "${rule}"
  done
  for rule in $(ip -6 rule list \
                |grep "from .* lookup ${RTABLE}" \
                |awk -F: '{print $1}'); do
    ip -6 rule delete pref "${rule}"
  done
}

rewrite_rules() {
  ips=($(get_ipv4s))
  if [[ $? -ne 0 ]]; then
    # If we get an error fetching the list of IPs from IMDS,
    # bail out early.
    logger "[rewrite_rules] Could not get IPv4 addresses for ${INTERFACE} from IMDS. Aborting"
    return
  fi
  ips+=($(get_delegated_prefix ipv4))

  ip6s=($(get_ipv6s))
  if [[ $? -ne 0 ]]; then
    # If we get an error fetching the list of IPs from IMDS,
    # bail out early.
    logger "[rewrite_rules] Could not get IPv6 addresses for ${INTERFACE} from IMDS. Aborting"
    return
  fi
  ip6s+=($(get_delegated_prefix ipv6))

  if [[ ${#ips[*]} -eq 0 ]]; then
    remove_rules
    return
  fi
  # This is the part we would do in rewrite_primary() if we knew
  # the gateway address.
  if [[ ${#ip6s[*]} -gt 0 && -z "$(ip -6 route show table ${RTABLE})" ]]; then
    gateway6=$(get_ipv6_gateway)
    # Manually add the route, then add it to ${route6_file} so it
    # gets brought down with the rest of the interface.
    ip -6 route add default via ${gateway6} dev ${INTERFACE} table ${RTABLE}

    [[ -e $route6_file ]] && egrep -v "(^|\s)table\s+${RTABLE}(\s|$)" > "${route6_file}.illinois-tmp"
    cat <<EOF >> "${route6_file}.illinois-tmp"
default via ${gateway6} dev ${INTERFACE} table ${RTABLE}
EOF
    mv "${route6_file}.illinois-tmp" "${route6_file}"
  fi

  logger "[rewrite_rules] Rewriting rules for ${INTERFACE}"
  # Retrieve a list of IP rules for the route table that belongs
  # to this interface. Treat this as the stale list. For each IP
  # address obtained from metadata, cross the corresponding rule
  # off the stale list if present. Otherwise, add a rule sending
  # outbound traffic from that IP to the interface route table.
  # Then, remove all other rules found in the stale list.

  if [[ $INTERFACE != "eth0" || -n "$(ip -4 route show table ${RTABLE})" ]]; then
    declare -A rules
    for rule in $(ip -4 rule list \
                  |grep "from .* lookup ${RTABLE}" \
                  |awk '{print $1$3}'); do
      split=(${rule//:/ })
      rules[${split[1]}]=${split[0]}
    done
    for ip in ${ips[@]}; do
      if [[ ${rules[${ip}]} ]]; then
        unset rules[${ip}]
      else
        ip -4 rule add from ${ip} lookup ${RTABLE}
      fi
    done
    for rule in "${!rules[@]}"; do
      ip -4 rule delete pref "${rules[${rule}]}"
    done
  fi

  # Now do the same, but for IPv6
  if [[ $INTERFACE != "eth0" || -n "$(ip -6 route show table ${RTABLE})" ]]; then
    declare -A rules6
    for rule in $(ip -6 rule list \
                  |grep "from .* lookup ${RTABLE}" \
                  |awk '{print $1$3}'); do
      split=(${rule/:/ }) # take care to only replace the first :
      rules6[${split[1]}]=${split[0]}
    done
    for ip in ${ip6s[@]}; do
      if [[ ${rules6[${ip}]} ]]; then
        unset rules6[${ip}]
      else
        ip -6 rule add from ${ip} lookup ${RTABLE}
      fi
    done
    for rule in "${!rules6[@]}"; do
      ip -6 rule delete pref "${rules6[${rule}]}"
    done
  fi
}
HERE
fi

if [[ ! -e /etc/dhcp/dhclient.d/illinois.sh ]]; then
    cat > /etc/dhcp/dhclient.d/illinois.sh <<"HERE"
#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the MIT License. See the LICENSE accompanying this file
# for the specific language governing permissions and limitations under
# the License.

INTERFACE="${interface}"
PREFIX="${new_prefix}"
. /etc/sysconfig/network-scripts/illinoisnet-functions

illinois_config () {
  if [[ $INTERFACE == "eth0" ]]; then
    rewrite_rules
  fi
}

illinois_restore () {
  if [[ $INTERFACE == "eth0" ]]; then
    remove_rules
  fi
}
HERE
    chmod 0755 /etc/dhcp/dhclient.d/illinois.sh
fi

if [[ ! -e /usr/local/bin/illinoisnet-ifup ]]; then
    cat > /usr/local/bin/illinoisnet-ifup <<"HERE"
#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the MIT License. See the LICENSE accompanying this file
# for the specific language governing permissions and limitations under
# the License.

if [[ $# -eq 1 ]]; then
  INTERFACE="${1}"
else
  echo "usage: ${0##*/} <device name>"
  exit 1
fi

if [[ $UID -ne 0 ]]; then
  echo "error: ${0##*/} must be run as root"
  exit 1
fi

. /etc/sysconfig/network-scripts/illinoisnet-functions

logger "[plug_interface] ${INTERFACE} plugged"
rewrite_primary
rewrite_rules
HERE
    chmod 0700 /usr/local/bin/illinoisnet-ifup
fi

if [[ ! -e /usr/local/bin/illinoisnet-ifdown ]]; then
    cat > /usr/local/bin/illinoisnet-ifdown <<"HERE"
#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the MIT License. See the LICENSE accompanying this file
# for the specific language governing permissions and limitations under
# the License.

if [[ $# -eq 1 ]]; then
  INTERFACE="${1}"
else
  echo "usage: ${0##*/} <device name>"
  exit 1
fi

if [[ $UID -ne 0 ]]; then
  echo "error: ${0##*/} must be run as root"
  exit 1
fi

. /etc/sysconfig/network-scripts/illinoisnet-functions

logger "[unplug_interface] ${INTERFACE} unplugged"
if [[ $INTERFACE = "eth0" ]]; then
  remove_rules
fi
HERE
    chmod 0700 /usr/local/bin/illinoisnet-ifdown
fi

if [[ ! -e /etc/udev/rules.d/54-illinois-network-interfaces.rules ]]; then
    cat > /etc/udev/rules.d/54-illinois-network-interfaces.rules <<"HERE"
ACTION=="add", SUBSYSTEM=="net", KERNEL=="eth*", TAG+="systemd", ENV{SYSTEMD_WANTS}+="illinoisnet-ifup@$env{INTERFACE}"
ACTION=="remove", SUBSYSTEM=="net", KERNEL=="eth*", RUN+="/usr/local/bin/illinoisnet-ifdown $env{INTERFACE}"
HERE
fi

if [[ ! -e /usr/local/lib/systemd/system/illinoisnet-ifup@.service ]]; then
    cat > /usr/local/lib/systemd/system/illinoisnet-ifup@.service <<"HERE"
[Unit]
Description=Enable elastic network interfaces (illinoisnet) %i
After=network-online.target ec2net-ifup@%i.service
#This makes sure all subprocesses will be killed if the ENI is removed
BindsTo=sys-subsystem-net-devices-%i.device

[Service]
RemainAfterExit=true
ExecStart=/usr/local/bin/illinoisnet-ifup %i
# Probably redundant but ensure we clean up aliases and ip rules
ExecStop=/usr/local/bin/illinoisnet-ifdown %i
HERE
    # This runs after eth0 has been brought up, so make sure to start our unit
    if ip addr show eth0; then
      /usr/local/bin/illinoisnet-ifup eth0 || :
    fi
fi

illinois_init_status finished
date > /var/lib/illinois-extra-enis-init
