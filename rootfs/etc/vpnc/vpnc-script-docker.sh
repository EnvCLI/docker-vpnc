#!/bin/sh
#
# Originally part of vpnc source code:
# © 2005-2012 Maurice Massar, Jörg Mayer, Antonio Borneo et al.
# © 2009-2012 David Woodhouse <dwmw2@infradead.org>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
#
################
#
# List of parameters passed through environment
#* reason                       -- why this script was called, one of: pre-init connect disconnect reconnect
#* VPNGATEWAY                   -- vpn gateway address (always present)
#* TUNDEV                       -- tunnel device (always present)
#* INTERNAL_IP4_ADDRESS         -- address (always present)
#* INTERNAL_IP4_MTU             -- mtu (often unset)
#* INTERNAL_IP4_NETMASK         -- netmask (often unset)
#* INTERNAL_IP4_NETMASKLEN      -- netmask length (often unset)
#* INTERNAL_IP4_NETADDR         -- address of network (only present if netmask is set)
#* INTERNAL_IP4_DNS             -- list of dns servers
#* INTERNAL_IP4_NBNS            -- list of wins servers
#* INTERNAL_IP6_ADDRESS         -- IPv6 address
#* INTERNAL_IP6_NETMASK         -- IPv6 netmask
#* INTERNAL_IP6_DNS             -- IPv6 list of dns servers
#* USE_INTERNET_DNS             -- Use the internet DNS instead of the VPN dns server?

env | sort

# Delete DNS info provided by VPN server to use internet DNS
# Comment following line to use DNS beyond VPN tunnel
if [ -n "$USE_INTERNET_DNS" ]; then
        unset INTERNAL_IP4_DNS
fi

# =========== script (variable) setup ====================================

PATH=/sbin:/usr/sbin:$PATH

OS="`uname -s`"

HOOKS_DIR=/etc/vpnc
DEFAULT_ROUTE_FILE=/var/run/vpnc/defaultroute
RESOLV_CONF_BACKUP=/var/run/vpnc/resolv.conf-backup
SCRIPTNAME=`basename $0`

# some systems, eg. Darwin & FreeBSD, prune /var/run on boot
if [ ! -d "/var/run/vpnc" ]; then
        mkdir -p /var/run/vpnc
        [ -x /sbin/restorecon ] && /sbin/restorecon /var/run/vpnc
fi

# stupid SunOS: no blubber in /usr/local/bin ... (on stdout)
IPROUTE="`which ip 2> /dev/null | grep '^/'`"

if ifconfig --help 2>&1 | grep BusyBox > /dev/null; then
        ifconfig_syntax_inet=""
else
        ifconfig_syntax_inet="inet"
fi

if [ "$OS" = "Linux" ]; then
        ifconfig_syntax_ptp="pointopoint"
        route_syntax_gw="gw"
        route_syntax_del="del"
        route_syntax_netmask="netmask"
else
        ifconfig_syntax_ptp=""
        route_syntax_gw=""
        route_syntax_del="delete"
        route_syntax_netmask="-netmask"
fi
if [ "$OS" = "SunOS" ]; then
        route_syntax_interface="-interface"
        ifconfig_syntax_ptpv6="$INTERNAL_IP6_ADDRESS"
else
        route_syntax_interface=""
        ifconfig_syntax_ptpv6=""
fi

if [ -r /etc/openwrt_release ] && [ -n "$OPENWRT_INTERFACE" ]; then
        . /etc/functions.sh
        include /lib/network
        MODIFYRESOLVCONF=modify_resolvconf_openwrt
        RESTORERESOLVCONF=restore_resolvconf_openwrt
elif [ -x /sbin/resolvconf ] && [ "$OS" != "FreeBSD" ]; then # Optional tool on Debian, Ubuntu, Gentoo - but not FreeBSD, it seems to work different
        MODIFYRESOLVCONF=modify_resolvconf_manager
        RESTORERESOLVCONF=restore_resolvconf_manager
else # Generic for any OS
        MODIFYRESOLVCONF=modify_resolvconf_generic
        RESTORERESOLVCONF=restore_resolvconf_generic
fi


# =========== script hooks =================================================

run_hooks() {
        HOOK="$1"

        if [ -d ${HOOKS_DIR}/${HOOK}.d ]; then
            for script in ${HOOKS_DIR}/${HOOK}.d/* ; do
                [ -f $script ] && . $script
            done
        fi
}

# =========== tunnel interface handling ====================================

do_ifconfig() {
        if [ -n "$INTERNAL_IP4_MTU" ]; then
                MTU=$INTERNAL_IP4_MTU
        elif [ -n "$IPROUTE" ]; then
                MTUDEV=`$IPROUTE route get "$VPNGATEWAY" | sed -ne 's/^.*dev \([a-z0-9]*\).*$/\1/p'`
                MTU=`$IPROUTE link show "$MTUDEV" | sed -ne 's/^.*mtu \([[:digit:]]\+\).*$/\1/p'`
                if [ -n "$MTU" ]; then
                        MTU=`expr $MTU - 88`
                fi
        fi

        if [ -z "$MTU" ]; then
                MTU=1412
        fi

        # Point to point interface require a netmask of 255.255.255.255 on some systems
        if [ -n "$IPROUTE" ]; then
                $IPROUTE link set dev "$TUNDEV" up mtu "$MTU"
                $IPROUTE addr add "$INTERNAL_IP4_ADDRESS/32" peer "$INTERNAL_IP4_ADDRESS" dev "$TUNDEV"
        else
                ifconfig "$TUNDEV" ${ifconfig_syntax_inet} "$INTERNAL_IP4_ADDRESS" $ifconfig_syntax_ptp "$INTERNAL_IP4_ADDRESS" netmask 255.255.255.255 mtu ${MTU} up
        fi

        if [ -n "$INTERNAL_IP4_NETMASK" ]; then
                set_network_route $INTERNAL_IP4_NETADDR $INTERNAL_IP4_NETMASK $INTERNAL_IP4_NETMASKLEN
        fi

        # If the netmask is provided, it contains the address _and_ netmask
        if [ -n "$INTERNAL_IP6_ADDRESS" ] && [ -z "$INTERNAL_IP6_NETMASK" ]; then
            INTERNAL_IP6_NETMASK="$INTERNAL_IP6_ADDRESS/128"
        fi
        if [ -n "$INTERNAL_IP6_NETMASK" ]; then
            if [ -n "$IPROUTE" ]; then
                $IPROUTE -6 addr add $INTERNAL_IP6_NETMASK dev $TUNDEV
            else
                # Unlike for Legacy IP, we don't specify the dest_address
                # here on *BSD. OpenBSD for one will refuse to accept
                # incoming packets to that address if we do.
                # OpenVPN does the same (gives dest_address for Legacy IP
                # but not for IPv6).
                # Only Solaris needs it; hence $ifconfig_syntax_ptpv6
                ifconfig "$TUNDEV" inet6 $INTERNAL_IP6_NETMASK $ifconfig_syntax_ptpv6 mtu $MTU up
            fi
        fi
}

destroy_tun_device() {
        case "$OS" in
        NetBSD|OpenBSD) # and probably others...
                ifconfig "$TUNDEV" destroy
                ;;
        FreeBSD)
                ifconfig "$TUNDEV" destroy > /dev/null 2>&1 &
                ;;
        esac
}

# =========== route handling ====================================

if [ -n "$IPROUTE" ]; then
        fix_ip_get_output () {
                sed -e 's/ /\n/g' | \
                    sed -ne '1p;/via/{N;p};/dev/{N;p};/src/{N;p};/mtu/{N;p}'
        }

        set_vpngateway_route() {
                $IPROUTE route add `$IPROUTE route get "$VPNGATEWAY" | fix_ip_get_output`
                $IPROUTE route flush cache
        }

        del_vpngateway_route() {
                $IPROUTE route $route_syntax_del "$VPNGATEWAY"
                $IPROUTE route flush cache
        }

        set_default_route() {
                $IPROUTE route | grep '^default' | fix_ip_get_output > "$DEFAULT_ROUTE_FILE"
                $IPROUTE route replace default dev "$TUNDEV"
                $IPROUTE route flush cache
        }

        set_network_route() {
                NETWORK="$1"
                NETMASK="$2"
                NETMASKLEN="$3"
                $IPROUTE route replace "$NETWORK/$NETMASKLEN" dev "$TUNDEV"
                $IPROUTE route flush cache
        }

        reset_default_route() {
                if [ -s "$DEFAULT_ROUTE_FILE" ]; then
                        $IPROUTE route replace `cat "$DEFAULT_ROUTE_FILE"`
                        $IPROUTE route flush cache
                        rm -f -- "$DEFAULT_ROUTE_FILE"
                fi
        }

        del_network_route() {
                NETWORK="$1"
                NETMASK="$2"
                NETMASKLEN="$3"
                $IPROUTE route $route_syntax_del "$NETWORK/$NETMASKLEN" dev "$TUNDEV"
                $IPROUTE route flush cache
        }

        set_ipv6_default_route() {
                # We don't save/restore IPv6 default route; just add a higher-priority one.
                $IPROUTE -6 route add default dev "$TUNDEV" metric 1
                $IPROUTE -6 route flush cache
        }

        set_ipv6_network_route() {
                NETWORK="$1"
                NETMASKLEN="$2"
                $IPROUTE -6 route replace "$NETWORK/$NETMASKLEN" dev "$TUNDEV"
                $IPROUTE route flush cache
        }

        reset_ipv6_default_route() {
                $IPROUTE -6 route del default dev "$TUNDEV"
                $IPROUTE route flush cache
        }

        del_ipv6_network_route() {
                NETWORK="$1"
                NETMASKLEN="$2"
                $IPROUTE -6 route del "$NETWORK/$NETMASKLEN" dev "$TUNDEV"
                $IPROUTE -6 route flush cache
        }
else # use route command
        get_default_gw() {
                # isn't -n supposed to give --numeric output?
                # apperently not...
                # Get rid of lines containing IPv6 addresses (':')
                netstat -r -n | awk '/:/ { next; } /^(default|0\.0\.0\.0)/ { print $2; }'
        }

        set_vpngateway_route() {
                route add -host "$VPNGATEWAY" $route_syntax_gw "`get_default_gw`"
        }

        del_vpngateway_route() {
                route $route_syntax_del -host "$VPNGATEWAY" $route_syntax_gw "`get_default_gw`"
        }

        set_default_route() {
                DEFAULTGW="`get_default_gw`"
                echo "$DEFAULTGW" > "$DEFAULT_ROUTE_FILE"
                route $route_syntax_del default $route_syntax_gw "$DEFAULTGW"
                route add default $route_syntax_gw "$INTERNAL_IP4_ADDRESS" $route_syntax_interface
        }

        set_network_route() {
                NETWORK="$1"
                NETMASK="$2"
                NETMASKLEN="$3"
                del_network_route "$NETWORK" "$NETMASK" "$NETMASKLEN"
                route add -net "$NETWORK" $route_syntax_netmask "$NETMASK" $route_syntax_gw "$INTERNAL_IP4_ADDRESS" $route_syntax_interface
        }

        reset_default_route() {
                if [ -s "$DEFAULT_ROUTE_FILE" ]; then
                        route $route_syntax_del default $route_syntax_gw "`get_default_gw`" $route_syntax_interface
                        route add default $route_syntax_gw `cat "$DEFAULT_ROUTE_FILE"`
                        rm -f -- "$DEFAULT_ROUTE_FILE"
                fi
        }

        del_network_route() {
                case "$OS" in
                Linux|NetBSD|OpenBSD|Darwin|SunOS) # and probably others...
                        # routes are deleted automatically on device shutdown
                        return
                        ;;
                esac
                NETWORK="$1"
                NETMASK="$2"
                NETMASKLEN="$3"
                route $route_syntax_del -net "$NETWORK" $route_syntax_netmask "$NETMASK" $route_syntax_gw "$INTERNAL_IP4_ADDRESS"
        }

        set_ipv6_default_route() {
                route add -inet6 default "$INTERNAL_IP6_ADDRESS" $route_syntax_interface
        }

        set_ipv6_network_route() {
                NETWORK="$1"
                NETMASK="$2"
                route add -inet6 -net "$NETWORK/$NETMASK" "$INTERNAL_IP6_ADDRESS" $route_syntax_interface
                :
        }

        reset_ipv6_default_route() {
                route $route_syntax_del -inet6 default "$INTERNAL_IP6_ADDRESS"
                :
        }

        del_ipv6_network_route() {
                NETWORK="$1"
                NETMASK="$2"
                route $route_syntax_del -inet6 "$NETWORK/$NETMASK" "$INTERNAL_IP6_ADDRESS"
                :
        }

fi

# =========== resolv.conf handling ====================================

# =========== resolv.conf handling for any OS =========================

modify_resolvconf_generic() {
        grep '^#@VPNC_GENERATED@' /etc/resolv.conf > /dev/null 2>&1 || cp -- /etc/resolv.conf "$RESOLV_CONF_BACKUP"
        NEW_RESOLVCONF="#@VPNC_GENERATED@ -- this file is generated by vpnc
# and will be overwritten by vpnc
# as long as the above mark is intact"

        # Remember the original value of CISCO_DEF_DOMAIN we need it later
        CISCO_DEF_DOMAIN_ORIG="$CISCO_DEF_DOMAIN"
        # Don't step on INTERNAL_IP4_DNS value, use a temporary variable
        INTERNAL_IP4_DNS_TEMP="$INTERNAL_IP4_DNS"
        exec 6< "$RESOLV_CONF_BACKUP"
        while read LINE <&6 ; do
                case "$LINE" in
                        nameserver*)
                                if [ -n "$INTERNAL_IP4_DNS_TEMP" ]; then
                                        read ONE_NAMESERVER INTERNAL_IP4_DNS_TEMP <<-EOF
        $INTERNAL_IP4_DNS_TEMP
EOF
                                        LINE="nameserver $ONE_NAMESERVER"
                                else
                                        LINE=""
                                fi
                                ;;
                        search*)
                                if [ -n "$CISCO_DEF_DOMAIN" ]; then
                                        LINE="$LINE $CISCO_DEF_DOMAIN"
                                        CISCO_DEF_DOMAIN=""
                                fi
                                ;;
                        domain*)
                                if [ -n "$CISCO_DEF_DOMAIN" ]; then
                                        LINE="domain $CISCO_DEF_DOMAIN"
                                        CISCO_DEF_DOMAIN=""
                                fi
                                ;;
                esac
                NEW_RESOLVCONF="$NEW_RESOLVCONF
$LINE"
        done
        exec 6<&-

        for i in $INTERNAL_IP4_DNS_TEMP ; do
                NEW_RESOLVCONF="$NEW_RESOLVCONF
nameserver $i"
        done
        if [ -n "$CISCO_DEF_DOMAIN" ]; then
                NEW_RESOLVCONF="$NEW_RESOLVCONF
search $CISCO_DEF_DOMAIN"
        fi
        echo "$NEW_RESOLVCONF" > /etc/resolv.conf
}

restore_resolvconf_generic() {
        if [ ! -f "$RESOLV_CONF_BACKUP" ]; then
                return
        fi
        grep '^#@VPNC_GENERATED@' /etc/resolv.conf > /dev/null 2>&1 && cat "$RESOLV_CONF_BACKUP" > /etc/resolv.conf
        rm -f -- "$RESOLV_CONF_BACKUP"
}

# === resolv.conf handling via UCI (OpenWRT) =========

modify_resolvconf_openwrt() {
        add_dns $OPENWRT_INTERFACE $INTERNAL_IP4_DNS
}

restore_resolvconf_openwrt() {
        remove_dns $OPENWRT_INTERFACE
}
# === resolv.conf handling via /sbin/resolvconf (Debian, Ubuntu, Gentoo)) =========

modify_resolvconf_manager() {
        NEW_RESOLVCONF=""
        for i in $INTERNAL_IP4_DNS; do
                NEW_RESOLVCONF="$NEW_RESOLVCONF
nameserver $i"
        done
        if [ -n "$CISCO_DEF_DOMAIN" ]; then
                NEW_RESOLVCONF="$NEW_RESOLVCONF
domain $CISCO_DEF_DOMAIN"
        fi
        echo "$NEW_RESOLVCONF" | /sbin/resolvconf -a $TUNDEV
}

restore_resolvconf_manager() {
        /sbin/resolvconf -d $TUNDEV
}

# ========= Toplevel state handling  =======================================

kernel_is_2_6_or_above() {
        case `uname -r` in
                1.*|2.[012345]*)
                        return 1
                        ;;
                *)
                        return 0
                        ;;
        esac
}

do_pre_init() {
        if [ "$OS" = "Linux" ]; then
                if (exec 6<> /dev/net/tun) > /dev/null 2>&1 ; then
                        :
                else # can't open /dev/net/tun
                        test -e /proc/sys/kernel/modprobe && `cat /proc/sys/kernel/modprobe` tun 2>/dev/null
                        # fix for broken devfs in kernel 2.6.x
                        if [ "`readlink /dev/net/tun`" = misc/net/tun \
                                -a ! -e /dev/net/misc/net/tun -a -e /dev/misc/net/tun ] ; then
                                ln -sf /dev/misc/net/tun /dev/net/tun
                        fi
                        # make sure tun device exists
                        if [ ! -e /dev/net/tun ]; then
                                mkdir -p /dev/net
                                mknod -m 0640 /dev/net/tun c 10 200
                                [ -x /sbin/restorecon ] && /sbin/restorecon /dev/net/tun
                        fi
                        # workaround for a possible latency caused by udev, sleep max. 10s
                        if kernel_is_2_6_or_above ; then
                                for x in `seq 100` ; do
                                        (exec 6<> /dev/net/tun) > /dev/null 2>&1 && break;
                                        sleep 0.1
                                done
                        fi
                fi
        fi
}

do_connect() {
        if [ -n "$CISCO_BANNER" ]; then
                echo "Connect Banner:"
                echo "$CISCO_BANNER" | while read LINE ; do echo "|" "$LINE" ; done
                echo
        fi

        # initialize vpn gateway route
        # set_vpngateway_route

        # initialize tun interface
        do_ifconfig

        # add vpn network routes
        if [ -n "$VPN_NETWORK" ]; then
                i=1
                while [ $i -lt `expr $VPN_NETWORK + 1` ] ; do
                        eval NETWORK="\${VPN_NETWORK_${i}_ADDR}"
                        eval NETMASK="\${VPN_NETWORK_${i}_MASK}"
                        eval NETMASKLEN="\${VPN_NETWORK_${i}_MASKLEN}"
                        set_network_route "$NETWORK" "$NETMASK" "$NETMASKLEN"
                        i=`expr $i + 1`
                done
        fi
}

do_disconnect() {
        # doesn't really matter, on disconnect we dispose of the container
        reset_default_route
        del_vpngateway_route

        if [ -n "$INTERNAL_IP4_DNS" ]; then
                $RESTORERESOLVCONF
        fi

        if [ -n "$IPROUTE" ]; then
                if [ -n "$INTERNAL_IP4_ADDRESS" ]; then
                        $IPROUTE addr del "$INTERNAL_IP4_ADDRESS/255.255.255.255" peer "$INTERNAL_IP4_ADDRESS" dev "$TUNDEV"
                fi
                # If the netmask is provided, it contains the address _and_ netmask
                if [ -n "$INTERNAL_IP6_ADDRESS" ] && [ -z "$INTERNAL_IP6_NETMASK" ]; then
                        INTERNAL_IP6_NETMASK="$INTERNAL_IP6_ADDRESS/128"
                fi
                if [ -n "$INTERNAL_IP6_NETMASK" ]; then
                        $IPROUTE -6 addr del $INTERNAL_IP6_NETMASK dev $TUNDEV
                fi
        else
                if [ -n "$INTERNAL_IP4_ADDRESS" ]; then
                        ifconfig "$TUNDEV" 0.0.0.0
                fi
                if [ -n "$INTERNAL_IP6_ADDRESS" ] && [ -z "$INTERNAL_IP6_NETMASK" ]; then
                        INTERNAL_IP6_NETMASK="$INTERNAL_IP6_ADDRESS/128"
                fi
                if [ -n "$INTERNAL_IP6_NETMASK" ]; then
                        ifconfig "$TUNDEV" inet6 del $INTERNAL_IP6_NETMASK
                fi
        fi

        destroy_tun_device
}

#### Main

if [ -z "$reason" ]; then
        echo "this script must be called from vpnc" 1>&2
        exit 1
fi

case "$reason" in
        pre-init)
                run_hooks pre-init
                do_pre_init
                ;;
        connect)
                run_hooks connect
                do_connect
                run_hooks post-connect
                ;;
        disconnect)
                run_hooks disconnect
                do_disconnect
                run_hooks post-disconnect
                ;;
        reconnect)
                run_hooks reconnect
                ;;
        *)
                echo "unknown reason '$reason'. Maybe vpnc-script is out of date" 1>&2
                exit 1
                ;;
esac

exit 0
