#!/bin/bash

EASYRSA_PKI="$OPENVPN/pki"
SERVER_IP=${PUBLIC_IP:-$(curl -s https://ifconfig.me)}

case "$1" in
    gen-client)
        CLIENT=$2
        DAYS=$3

        if [ -z "$CLIENT" ]; then
            echo "Errore: nome del client non specificato."
            echo "Uso: manage.sh gen-client <name> [days]"
            exit 1
        fi

        EASYRSA_ARGS=("--batch" "--pki-dir=$EASYRSA_PKI")
        if [ -n "$DAYS" ]; then
            EASYRSA_ARGS+=("--days=$DAYS")
        fi
        easyrsa "${EASYRSA_ARGS[@]}" build-client-full "$CLIENT" nopass

        echo "--- Creating file $CLIENT.ovpn ---"
        cat <<EOF > "$OPENVPN/$CLIENT.ovpn"
client
dev tun
proto ${VPN_PROTO:-udp}
remote $SERVER_IP ${VPN_PORT:-1194}
resolv-retry infinite
nobind
remote-cert-tls server
cipher AES-256-GCM
verb 3
<ca>
$(cat $EASYRSA_PKI/ca.crt)
</ca>
<cert>
$(cat $EASYRSA_PKI/issued/$CLIENT.crt)
</cert>
<key>
$(cat $EASYRSA_PKI/private/$CLIENT.key)
</key>
<tls-auth>
$(cat $EASYRSA_PKI/ta.key)
</tls-auth>
key-direction 1
EOF
        echo "Ready! File created in $OPENVPN/$CLIENT.ovpn"
        ;;
    revoke-client)
        CLIENT=$2
        if [ -z "$CLIENT" ]; then
            echo "Errore: nome del client non specificato."
            echo "Uso: manage.sh revoke-client <name>"
            exit 1
        fi

        easyrsa --batch --pki-dir="$EASYRSA_PKI" revoke "$CLIENT"
        easyrsa --batch --pki-dir="$EASYRSA_PKI" gen-crl
        cp "$EASYRSA_PKI/crl.pem" "$OPENVPN/crl.pem"
        echo "Revoked access for $CLIENT"
        ;;
    *)
        echo "Uso: manage.sh gen-client <name> [days] | revoke-client <name>"
        echo "       'days' è opzionale (0 per infinito)."
        ;;
esac
