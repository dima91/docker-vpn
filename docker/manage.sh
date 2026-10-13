#!/bin/bash
set -e

EASYRSA_PKI="$OPENVPN/pki"

case "$1" in
    gen-client)
        CLIENT=$2
        DAYS=$3

        if [ -z "$CLIENT" ]; then
            echo "Errore: nome del client non specificato."
            echo "Uso: manage.sh gen-client <name> [days]"
            exit 1
        fi

        # Un certificato non può essere senza scadenza: 0 vale la durata della CA
        if [ "$DAYS" = 0 ]; then
            DAYS=3650
        fi
        if [ -n "$DAYS" ] && ! [[ "$DAYS" =~ ^[1-9][0-9]*$ ]]; then
            echo "Errore: 'days' deve essere un numero intero di giorni."
            exit 1
        fi

        # ta.key è l'ultimo file della PKI creato da entrypoint.sh al primo avvio
        if [ ! -s "$EASYRSA_PKI/ta.key" ]; then
            echo "Errore: il server non ha ancora finito l'inizializzazione, riprova tra poco."
            exit 1
        fi

        SERVER_IP=$PUBLIC_IP
        if [ -z "$SERVER_IP" ]; then
            SERVER_IP=$(curl -fsS --max-time 10 https://ifconfig.me) || true
        fi
        # Deve essere un indirizzo o un nome host, non vuoto né una pagina di errore
        if ! [[ "$SERVER_IP" =~ ^[A-Za-z0-9.:-]+$ ]]; then
            echo "Errore: impossibile determinare l'indirizzo pubblico del server."
            echo "Imposta la variabile PUBLIC_IP."
            exit 1
        fi

        EASYRSA_ARGS=("--batch" "--pki-dir=$EASYRSA_PKI")
        if [ -n "$DAYS" ]; then
            EASYRSA_ARGS+=("--days=$DAYS")
        fi
        easyrsa "${EASYRSA_ARGS[@]}" build-client-full "$CLIENT" nopass

        # Un cat fallito dentro l'heredoc non interrompe lo script: si controlla prima
        for FILE in "$EASYRSA_PKI/ca.crt" "$EASYRSA_PKI/issued/$CLIENT.crt" \
                    "$EASYRSA_PKI/private/$CLIENT.key" "$EASYRSA_PKI/ta.key"; do
            if [ ! -s "$FILE" ]; then
                echo "Errore: file mancante o vuoto: $FILE"
                exit 1
            fi
        done

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
$(cat "$EASYRSA_PKI/ca.crt")
</ca>
<cert>
$(cat "$EASYRSA_PKI/issued/$CLIENT.crt")
</cert>
<key>
$(cat "$EASYRSA_PKI/private/$CLIENT.key")
</key>
<tls-auth>
$(cat "$EASYRSA_PKI/ta.key")
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

        if [ ! -f "$EASYRSA_PKI/issued/$CLIENT.crt" ]; then
            echo "Errore: nessun certificato attivo per il client '$CLIENT'."
            exit 1
        fi

        easyrsa --batch --pki-dir="$EASYRSA_PKI" revoke "$CLIENT"
        # server.conf punta a questa CRL: OpenVPN la rilegge a ogni nuova connessione
        easyrsa --batch --pki-dir="$EASYRSA_PKI" gen-crl
        echo "Revoked access for $CLIENT"
        ;;
    *)
        echo "Uso: manage.sh gen-client <name> [days] | revoke-client <name>"
        echo "       'days' è la validità del certificato in giorni: è opzionale"
        echo "       (825 se omesso, 0 per il massimo: 3650, la durata della CA)."
        exit 1
        ;;
esac
