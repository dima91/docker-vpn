#!/bin/bash
set -e

EASYRSA_PKI="$OPENVPN/pki"

if [ ! -f "$OPENVPN/server.conf" ]; then
    echo "--- Setting up PKI ---"
    
    # Inizializza la struttura
    easyrsa --batch --pki-dir="$EASYRSA_PKI" init-pki
    easyrsa --batch --pki-dir="$EASYRSA_PKI" build-ca nopass
    easyrsa --batch --pki-dir="$EASYRSA_PKI" gen-dh
    easyrsa --batch --pki-dir="$EASYRSA_PKI" build-server-full vpn_server nopass
    easyrsa --batch --pki-dir="$EASYRSA_PKI" gen-crl
    
    # Chiave TLS-Auth (Sintassi OpenVPN 2.6+)
    openvpn --genkey secret "$EASYRSA_PKI/ta.key"

    echo "--- Building derver configuration ---"
    cat <<EOF > "$OPENVPN/server.conf"
port ${VPN_PORT:-1194}
proto ${VPN_PROTO:-udp}
dev tun
ca $EASYRSA_PKI/ca.crt
cert $EASYRSA_PKI/issued/vpn_server.crt
key $EASYRSA_PKI/private/vpn_server.key
dh $EASYRSA_PKI/dh.pem
tls-auth $EASYRSA_PKI/ta.key 0
server ${VPN_SUBNET:-10.8.0.0} 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
keepalive 10 120
cipher AES-256-GCM
persist-key
persist-tun
verb 3
EOF
fi

# Routing
iptables -t nat -A POSTROUTING -s ${VPN_SUBNET:-10.8.0.0}/24 -o eth0 -j MASQUERADE

exec "$@"

