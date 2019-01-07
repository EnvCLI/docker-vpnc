#!/bin/bash
set -e

# accept and forward v4/v6 via NAT
#sudo iptables -t nat -A POSTROUTING -s 10.2.0.0/24 -m policy --dir out --pol ipsec -j ACCEPT
#sudo iptables -t nat -A POSTROUTING -s 10.2.0.0/24 -j MASQUERADE
#sudo ip6tables -t nat -A POSTROUTING -s fec0::/120 -m policy --dir out --pol ipsec -j ACCEPT
#sudo ip6tables -t nat -A POSTROUTING -s fec0::/120 -j MASQUERADE

# config file
cat > /etc/vpnc/default.conf <<EOF
# VPN Host
IPSec gateway ${VPNC_GATEWAY}

# VPN ID
IPSec ID ${VPNC_ID}

# VPN PSK
IPSec secret ${VPNC_SECRET}
IKE Authmode psk

# VPN Username
Xauth username ${VPNC_USERNAME}

# VPN Password
Xauth password ${VPNC_PASSWORD}
EOF

exec "$@"
