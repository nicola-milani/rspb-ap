#!/bin/bash
#
# Configuration files
#
PROGNAME=${0##*/}
. /etc/athena/setup.conf

rspb_init() {

    #
    # upgrade and fix some requirements
    #
    apt update
    apt upgrade -y
    apt install dnsmasq hostapd -y
    systemctl stop dnsmasq
    systemctl stop hostapd
    systemctl enable ssh
    systemctl start ssh

    #
    # Replace default interfaces with correct source options after kernel 3.5
    #
    cat >/etc/network/interfaces <<EOF
# interfaces(5) file used by ifup(8) and ifdown(8)
# Please note that this file is written to be used with dhcpcd
# For static IP, consult /etc/dhcpcd.conf and 'man dhcpcd.conf'

# Include files from /etc/network/interfaces.d:
source /etc/network/interfaces.d/*


EOF

    do_set_dhcpcd

    service dhcpcd restart
    while true; do
        if [ $(systemctl is-active dhcpcd) == "active" ]; then
            break
        fi
        sleep 1
    done

    mv /etc/dnsmasq.conf /etc/dnsmasq.conf.orig
    cat >/etc/dnsmasq.conf <<EOF
#####################################
#### Network configuration for AP ###
#### Use a "no standard LAN"      ###
#####################################

interface=${NIC}      # Use the require wireless interface - usually wlan0
address=${ADDRESS_BIND}
dhcp-range=${DHCP_RANGE}
addn-hosts=/etc/hosts-dns
log-queries
log-dhcp
listen-address=127.0.0.1


EOF

    systemctl reload dnsmasq

    cat >/etc/hostapd/hostapd.conf <<EOF

interface=${NIC}
driver=nl80211
ssid=AthenaSecurityNet
hw_mode=g
channel=7
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
#wpa=2
#wpa_passphrase=1234567890
#wpa_key_mgmt=WPA-PSK
#wpa_pairwise=TKIP
rsn_pairwise=CCMP
EOF

    sed -i 's/#DAEMON_CONF=""/DAEMON_CONF="\/etc\/hostapd\/hostapd.conf"/g' /etc/default/hostapd

    export LANGUAGE=en_GB.UTF-8
    export LANG=en_GB.UTF-8
    export LC_ALL=en_GB.UTF-8
    locale-gen en_GB.UTF-8
    dpkg-reconfigure --frontend noninteractive locales

    systemctl unmask hostapd
    systemctl enable hostapd
    systemctl start hostapd
    while true; do
        if [ $(systemctl is-active hostapd) == "active" ]; then
            break
        fi
        sleep 1
    done
    systemctl start dnsmasq
    while true; do
        if [ $(systemctl is-active dnsmasq) == "active" ]; then
            break
        fi
        sleep 1
    done

    sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/g' /etc/sysctl.conf

    apt install nginx libnss-mdns -y

    echo "athena-security-board" >/etc/hostname

    sed -i 's/raspberrypi/athena-security-board/g' /etc/hosts
    echo "${ADDRESS} athena-security-board.local athena-security-board" >/etc/hosts-dns

    ##
    #Standard template for wpasupplicant
    #
    mkdir -p /var/www/html/setup
    do_set_wpa_supplicant

  while true; do
        if [ $(systemctl is-active hostapd) == "active" ]; then
            break
        fi
        sleep 1
    done
}
do_set_wpa_supplicant(){
    NAME=$1
    PASSWORD=$2
    if [ -z $NAME ]; then 
        cat >/etc/wpa_supplicant/wpa_supplicant.conf <<EOF
country=IT
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
network={
    ssid="ESSID"
    psk="PASSWORD"
}
EOF
    elif [ -z $PASSWORD ]; then
            cat >/etc/wpa_supplicant/wpa_supplicant.conf <<EOF
country=IT
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
network={
    ssid="${NAME}"
    key_mgmt=NONE
}
EOF
    else
            cat >/etc/wpa_supplicant/wpa_supplicant.conf <<EOF
country=IT
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
network={
    ssid="${NAME}"
    psk="${PASSWORD}"
}
EOF
    fi
  chmod 600 /etc/wpa_supplicant/wpa_supplicant.conf
}
do_set_dhcpcd() {
    #
    # Set dchpcd with standard template
    #
    cat >/etc/dhcpcd.conf <<EOF
#####################################
#### Network configuration for AP ###
#### Use a "no standard LAN"      ###
#####################################

interface ${NIC}
    static ip_address=${DEFAULT_NETWORK}
    nohook wpa_supplicant

EOF
}
####
# Connect to local wifi
####
do_discovery_essid() {

    OIFS="$IFS"
    IFS=$'\n'
    [ -f /var/www/html/setup/essid_list ] && rm /var/www/html/setup/essid_list
    for w in $(iwlist wlan0 scan | grep ESSID); do
        echo $w | cut -d : -f2 >> /var/www/html/setup/essid_list
    done
    cat /var/www/html/setup/essid_list
}

do_connect() {
    NAME=$1
    PASSWORD=$2
    do_set_wpa_supplicant $NAME $PASSWORD
    systemctl stop hostapd
    systemctl stop dnsmasq
    cat >/etc/dhcpcd.conf <<EOF
clientid
persistent
option rapid_commit
option domain_name_servers, domain_name, domain_search, host_name
option classless_static_routes
option interface_mtu
require dhcp_server_identifier
slaac private
EOF
    systemctl daemon-reload

    # ESSID=$1
    # PASSWORD=$2

    # sed -i s/ESSID/"$ESSID"/ /etc/wpa_supplicant/wpa_supplicant.conf
    # sed -i s/PASSWORD/"$PASSWORD"/ /etc/wpa_supplicant/wpa_supplicant.conf

    cat >/etc/network/interfaces.d/wlan0.conf <<EOF
auto ${NIC}
allow-hotplug ${NIC}
iface ${NIC} inet dhcp
wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
iface default inet dhcp
EOF

    wpa_cli -i ${NIC} reconfigure
    ifup ${NIC}
    COUNTER=0
    while [ $COUNTER -lt 10 ]; do
        IP=$(ip addr show ${NIC} | grep "inet\b" | awk '{print $2}' | cut -d/ -f1)
        if [ ! -z ${IP} ]; then
            systemctl disable hostapd
            systemctl disable dnsmasq
            break
        fi
        sleep 1
        let COUNTER=COUNTER+1
    done
    IP=$(ip addr show ${NIC} | grep "inet\b" | awk '{print $2}' | cut -d/ -f1)
    if [ ! -z ${IP} ]; then
        do_reset
    fi

}

do_reset() {
    rm -f /etc/network/interfaces.d/wlan0.conf
    systemctl enable hostapd
    systemctl enable dnsmasq
    systemctl start hostapd
    systemctl start dnsmasq
    do_set_dhcpcd
    systemctl daemon-reload
    systemctl start dhcpcd
}

do_getStatus() {
    #check if there are some nic already configured
    IP=$(ip addr show ${NIC} | grep "inet\b" | awk '{print $2}' | cut -d/ -f1)
    if [ -f /etc/network/interfaces.d/wlan0.conf ] &&
        [ ! -z ${IP} ] &&
        [ $(systemctl is-active hostapd) == "inactive" ] &&
        [ $(systemctl is-active dnsmasq) == "inactive" ]; then
        echo "Status: Connected to local network"
    fi
    IP=$(ip addr show ${NIC} | grep "inet\b" | awk '{print $2}' | cut -d/ -f1)
    if [ ! -f /etc/network/interfaces.d/wlan0.conf ] &&
        [ ! -z ${IP} ] &&
        [ $(systemctl is-active hostapd) == "active" ] &&
        [ $(systemctl is-active dnsmasq) == "active" ]; then
        echo "Status: AP mode"
    fi

}

logo() {

    printf '%s\n' '           _   _                         _____ _____  _      '
    printf '%s\n' '      /\  | | | |                       / ____|  __ \| |     '
    printf '%s\n' '     /  \ | |_| |__   ___ _ __   __ _  | (___ | |__) | |     '
    printf '%s\n' '    / /\ \| __| ''_ \ / _ \ ''_ \ / _` |  \___ \|  _  /| |     '
    printf '%s\n' '   / ____ \ |_| | | |  __/ | | | (_| |  ____) | | \ \| |____ '
    printf '%s\n' '  /_/    \_\__|_| |_|\___|_| |_|\__,_| |_____/|_|  \_\______|'

}

usage() {
    logo

    cat <<EOF

    Get info
        --findEssid                          list available essid, save to /tmp/essidlist
        --getStatus                          show current running mode

    Edit and create
        --connect <config_file>              connect to essid with selected configuration file
        --reset                              return to default mode
        --init                               rebuild default raspberry
        --help :                             show this messge
EOF
}

SHORTOPTS="hvn:"
LONGOPTS="help,init,reset,connect,getStatus,findEssid"

ARGS=$(getopt -s bash --options $SHORTOPTS --longoptions $LONGOPTS --name $PROGNAME -- "$@")
eval set -- "$ARGS"

while true; do
    case $1 in
    --help)
        usage
        exit 0
        ;;
    --init)
        rspb_init
        do_reset
        exit 0
        ;;
    --reset)
        do_reset 
        exit 0
        ;;
    --connect)
        shift
        shift
        NAME=$1
        PASSWORD=$2
        do_connect $NAME $PASSWORD
        exit $?
        ;;
    --getStatus)
        do_getStatus
        exit 0
        ;;
    --findEssid)
        do_discovery_essid
        exit 0
        ;;
    *)
        shift
        if [ -n "$1" ]; then
            echo "Error: bad argument, use manage.sh --help"
            exit 1
        fi
        break
        ;;
    esac
    shift
done
