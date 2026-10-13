#!/bin/bash
set -e

# shellcheck source=common.sh
. /usr/local/lib/vpn-common.sh

uso() {
    echo "Uso: manage.sh gen-client <name> [days] | export-client <name> | revoke-client <name>"
    echo "       gen-client emette un nuovo certificato e scrive il profilo <name>.ovpn;"
    echo "       'days' è la validità in giorni, opzionale (825 se omesso, 0 per il massimo: $MAX_DAYS)."
    echo "       export-client riscrive il profilo di un client esistente con l'indirizzo, la porta"
    echo "       e il protocollo attuali del server, senza emettere un nuovo certificato."
}

# nome_client <nome> <uso>: il nome deve esserci ed essere valido
nome_client() {
    if [ -z "$1" ]; then
        echo "Errore: nome del client non specificato." >&2
        echo "Uso: manage.sh $2" >&2
        exit 1
    fi
    valid_name "$1" ||
        die "nome del client '$1' non valido: da 1 a 64 caratteri tra lettere, cifre, '.', '_' e '-', iniziando con una lettera o una cifra ('vpn_server' e 'ca' sono riservati)."
}

# La PKI è pronta solo a fine inizializzazione: prima mancano la chiave TLS e i certificati
server_pronto() {
    if [ -e "$PKI_MARKER" ] || [ ! -s "$PKI/ta.key" ]; then
        die "il server non ha ancora finito l'inizializzazione, riprova tra poco."
    fi
}

# Indirizzo da scrivere nei profili: PUBLIC_IP, altrimenti quello visto da ifconfig.me
indirizzo_pubblico() {
    local ip=$PUBLIC_IP
    if [ -z "$ip" ]; then
        ip=$(curl -fsS --max-time 10 https://ifconfig.me) || true
    fi
    # Deve essere un indirizzo o un nome host, non vuoto né una pagina di errore
    [[ "$ip" =~ ^[A-Za-z0-9.:-]+$ ]] ||
        die "impossibile determinare l'indirizzo pubblico del server. Imposta la variabile PUBLIC_IP."
    echo "$ip"
}

# scrivi_profilo <client> <indirizzo>: il profilo contiene la chiave privata del client
# e la chiave TLS, quindi lo può leggere solo root (permessi 600).
scrivi_profilo() {
    local client=$1 ip=$2 file="$OPENVPN/$1.ovpn" f
    # Un cat fallito dentro l'heredoc non interrompe lo script: si controlla prima
    for f in "$PKI/ca.crt" "$PKI/issued/$client.crt" "$PKI/private/$client.key" "$PKI/ta.key"; do
        if [ ! -s "$f" ]; then
            echo "Errore: file mancante o vuoto: $f" >&2
            return 1
        fi
    done

    echo "--- Creating file $client.ovpn ---"
    rm -f "$file"
    (
        umask 077
        cat <<EOF > "$file"
client
dev tun
proto $VPN_PROTO
remote $ip $VPN_PORT
resolv-retry infinite
nobind
remote-cert-tls server
cipher AES-256-GCM
verb 3
<ca>
$(cat "$PKI/ca.crt")
</ca>
<cert>
$(cat "$PKI/issued/$client.crt")
</cert>
<key>
$(cat "$PKI/private/$client.key")
</key>
<tls-auth>
$(cat "$PKI/ta.key")
</tls-auth>
key-direction 1
EOF
    ) || {
        # Chiamata in un contesto "||" la funzione non ha set -e: l'errore va gestito qui
        echo "Errore: scrittura di $file non riuscita." >&2
        return 1
    }
    echo "Ready! File created in $file"
}

case "$1" in
    gen-client)
        CLIENT=$2
        DAYS=$3
        nome_client "$CLIENT" "gen-client <name> [days]"

        # Un certificato non può essere senza scadenza: 0 vale la durata della CA
        if [ "$DAYS" = 0 ]; then
            DAYS=$MAX_DAYS
        fi
        if [ -n "$DAYS" ] && ! [[ "$DAYS" =~ ^[1-9][0-9]*$ ]]; then
            die "'days' deve essere un numero intero di giorni."
        fi

        server_pronto
        if [ -e "$PKI/issued/$CLIENT.crt" ]; then
            die "il client '$CLIENT' esiste già: 'manage.sh export-client $CLIENT' ne riscrive il profilo, 'revoke-client' lo sostituisce."
        fi
        # L'indirizzo si cerca prima di emettere il certificato: se manca non resta niente a metà
        SERVER_IP=$(indirizzo_pubblico)

        EASYRSA_ARGS=()
        if [ -n "$DAYS" ]; then
            EASYRSA_ARGS+=("--days=$DAYS")
        fi
        ersa "${EASYRSA_ARGS[@]}" build-client-full "$CLIENT" nopass

        scrivi_profilo "$CLIENT" "$SERVER_IP" || {
            echo "Il certificato di $CLIENT è stato emesso ma il profilo no: riprova con 'manage.sh export-client $CLIENT'." >&2
            exit 1
        }
        ;;
    export-client)
        CLIENT=$2
        nome_client "$CLIENT" "export-client <name>"
        server_pronto
        [ -s "$PKI/issued/$CLIENT.crt" ] || die "nessun certificato attivo per il client '$CLIENT'."
        SERVER_IP=$(indirizzo_pubblico)
        scrivi_profilo "$CLIENT" "$SERVER_IP" || exit 1
        ;;
    revoke-client)
        CLIENT=$2
        nome_client "$CLIENT" "revoke-client <name>"
        server_pronto

        # Il comando si può ripetere: se una esecuzione si è fermata dopo la revoca ma
        # prima di rigenerare la CRL, la ripetizione completa il lavoro.
        if [ -f "$PKI/issued/$CLIENT.crt" ]; then
            ersa revoke "$CLIENT"
        elif grep -qE "^R[[:space:]].*/CN=${CLIENT//./\\.}\$" "$PKI/index.txt"; then
            echo "Il certificato di $CLIENT era già revocato: rigenero la CRL."
        else
            die "nessun client '$CLIENT'."
        fi
        # server.conf punta a questa CRL: OpenVPN la rilegge a ogni nuova connessione
        ersa gen-crl
        rm -f "$OPENVPN/$CLIENT.ovpn"
        echo "Revoked access for $CLIENT"
        ;;
    *)
        uso
        exit 1
        ;;
esac
