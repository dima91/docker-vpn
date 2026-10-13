#!/bin/bash
set -e

EASYRSA_PKI="$OPENVPN/pki"

# Inizializza la struttura. In batch init-pki cancella una PKI esistente senza
# chiedere conferma, quindi va eseguito solo se la cartella non esiste ancora.
if [ ! -d "$EASYRSA_PKI" ]; then
    echo "--- Setting up PKI ---"
    easyrsa --batch --pki-dir="$EASYRSA_PKI" init-pki
fi

# Ogni passo viene saltato se il suo file esiste già, così un'inizializzazione
# interrotta riprende da dove si era fermata.
if [ ! -s "$EASYRSA_PKI/ca.crt" ]; then
    easyrsa --batch --pki-dir="$EASYRSA_PKI" build-ca nopass
fi
if [ ! -s "$EASYRSA_PKI/dh.pem" ]; then
    # Un gen-dh interrotto lascia un file vuoto che easyrsa rifiuta di sovrascrivere
    rm -f "$EASYRSA_PKI/dh.pem"
    easyrsa --batch --pki-dir="$EASYRSA_PKI" gen-dh
fi
# Il certificato del server dura quanto la CA (10 anni) invece degli 825 giorni
# predefiniti di easy-rsa: quando scade nessun client riesce più a connettersi.
if [ ! -s "$EASYRSA_PKI/issued/vpn_server.crt" ]; then
    easyrsa --batch --pki-dir="$EASYRSA_PKI" --days=3650 build-server-full vpn_server nopass
# Quelli già emessi a 825 giorni vengono rinnovati all'avvio quando mancano meno
# di 30 giorni alla scadenza (la finestra in cui easy-rsa consente il rinnovo).
elif ! openssl x509 -in "$EASYRSA_PKI/issued/vpn_server.crt" -noout -checkend $((30 * 86400)) > /dev/null; then
    echo "--- Renewing server certificate ---"
    easyrsa --batch --pki-dir="$EASYRSA_PKI" --days=3650 renew vpn_server nopass ||
        echo "Errore: rinnovo del certificato del server non riuscito." >&2
fi
if [ ! -s "$EASYRSA_PKI/ta.key" ]; then
    # Chiave TLS-Auth (Sintassi OpenVPN 2.6+)
    openvpn --genkey secret "$EASYRSA_PKI/ta.key"
fi

# Con crl-verify una CRL scaduta fa rifiutare tutti i client, quindi viene
# rigenerata a ogni avvio (la validità è EASYRSA_CRL_DAYS, vedi Dockerfile).
easyrsa --batch --pki-dir="$EASYRSA_PKI" gen-crl

# server.conf viene riscritto a ogni avvio, così porta, protocollo e subnet
# seguono sempre le variabili d'ambiente (e la regola di NAT più sotto).
# Una configurazione non generata da questo script viene conservata in .bak.
if [ -f "$OPENVPN/server.conf" ] && ! grep -q '^# Generato da entrypoint.sh' "$OPENVPN/server.conf"; then
    cp "$OPENVPN/server.conf" "$OPENVPN/server.conf.bak"
fi

# Il tunnel è solo IPv4: senza altro, un client dual-stack continua a usare l'IPv6
# della sua rete fuori dalla VPN. Lo si instrada nel tunnel, dove il client lo
# rifiuta. VPN_BLOCK_IPV6=0 lo disattiva: serve ai client con IPv6 disabilitato
# nel kernel, che non possono configurare l'indirizzo IPv6 e non si connettono.
REDIRECT_FLAGS="def1 bypass-dhcp"
IPV6_BLOCK=""
if [ "${VPN_BLOCK_IPV6:-1}" != 0 ]; then
    REDIRECT_FLAGS="def1 ipv6 bypass-dhcp"
    IPV6_BLOCK='push "ifconfig-ipv6 fd15:53b6:dead::2/64 fd15:53b6:dead::1"
push "block-ipv6"'
fi

echo "--- Building server configuration ---"
cat <<EOF > "$OPENVPN/server.conf"
# Generato da entrypoint.sh a ogni avvio: le modifiche manuali vengono sovrascritte.
port ${VPN_PORT:-1194}
proto ${VPN_PROTO:-udp}
dev tun
ca $EASYRSA_PKI/ca.crt
cert $EASYRSA_PKI/issued/vpn_server.crt
key $EASYRSA_PKI/private/vpn_server.key
dh $EASYRSA_PKI/dh.pem
tls-auth $EASYRSA_PKI/ta.key 0
crl-verify $EASYRSA_PKI/crl.pem
server ${VPN_SUBNET:-10.8.0.0} 255.255.255.0
push "redirect-gateway $REDIRECT_FLAGS"
$IPV6_BLOCK
push "dhcp-option DNS 1.1.1.1"
keepalive 10 120
cipher AES-256-GCM
persist-key
persist-tun
verb 3
EOF

# Routing: NAT per tutto ciò che esce dalla subnet VPN, qualunque sia l'interfaccia
# di uscita. Con network_mode: host le regole sopravvivono al riavvio, da cui il -C.
NAT_RULE=(POSTROUTING -s "${VPN_SUBNET:-10.8.0.0}/24" ! -d "${VPN_SUBNET:-10.8.0.0}/24" -j MASQUERADE)
iptables -t nat -C "${NAT_RULE[@]}" 2>/dev/null || iptables -t nat -A "${NAT_RULE[@]}"

exec "$@"

