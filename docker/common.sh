#!/bin/bash
# shellcheck disable=SC2034  # variabili usate dagli script che caricano questo file
# Valori e funzioni comuni a entrypoint.sh e manage.sh (caricato con "source").

: "${OPENVPN:=/etc/openvpn}"
PKI="$OPENVPN/pki"
# Esiste solo mentre la PKI viene creata: se all'avvio c'è ancora, l'avvio precedente
# è stato interrotto e la PKI è da rifare. manage.sh non emette nulla finché esiste.
PKI_MARKER="$OPENVPN/.pki-init"
# Durata della CA e massimo per i certificati, in giorni
MAX_DAYS=3650

# Con ":=" anche una variabile impostata ma vuota (come passa compose) prende il predefinito
: "${VPN_PORT:=1194}"
: "${VPN_PROTO:=udp}"
: "${VPN_SUBNET:=10.8.0.0}"
: "${VPN_DNS:=1.1.1.1}"
VPN_PROTO=${VPN_PROTO,,}
VPN_DNS=${VPN_DNS// /}

die() { echo "Errore: $*" >&2; exit 1; }

# easyrsa senza domande sulla PKI del server. Il batch non è nell'ambiente
# dell'immagine di proposito: chi lancia easyrsa a mano con docker exec deve
# ricevere la richiesta di conferma prima che init-pki cancelli la PKI.
ersa() { easyrsa --batch --pki-dir="$PKI" "$@"; }

# to_bool <valore>: stampa 1 o 0; fallisce se il valore non è un booleano
to_bool() {
    case "${1,,}" in
        1|true|yes|on)  echo 1 ;;
        0|false|no|off) echo 0 ;;
        *) return 1 ;;
    esac
}

# Nome di un client: sicuro come nome di file e come CN, e diverso dai nomi del server
valid_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] && [ "$1" != vpn_server ] && [ "$1" != ca ]
}

# Controlla le variabili d'ambiente prima di usarle in server.conf e in iptables:
# un errore di battitura deve dare un messaggio chiaro, non un riavvio continuo.
validate_env() {
    local ottetto='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])' ip
    [[ "$VPN_SUBNET" =~ ^$ottetto\.$ottetto\.$ottetto\.0$ ]] ||
        die "VPN_SUBNET='$VPN_SUBNET' non valida: serve l'indirizzo di una rete /24, ad esempio 10.8.0.0."
    { [[ "$VPN_PORT" =~ ^[0-9]+$ ]] && [ "$VPN_PORT" -ge 1 ] && [ "$VPN_PORT" -le 65535 ]; } 2>/dev/null ||
        die "VPN_PORT='$VPN_PORT' non valida: serve un numero da 1 a 65535."
    [[ "$VPN_PROTO" =~ ^(udp|tcp)$ ]] ||
        die "VPN_PROTO='$VPN_PROTO' non valida: usa udp o tcp."
    if [ -n "${VPN_BLOCK_IPV6:-}" ]; then
        to_bool "$VPN_BLOCK_IPV6" >/dev/null ||
            die "VPN_BLOCK_IPV6='$VPN_BLOCK_IPV6' non valida: usa 1 o 0 (anche true/false, yes/no, on/off)."
    fi
    local dns
    IFS=, read -ra dns <<< "$VPN_DNS"
    for ip in "${dns[@]}"; do
        [[ "$ip" =~ ^$ottetto\.$ottetto\.$ottetto\.$ottetto$ || "$ip" =~ ^[0-9A-Fa-f:]+:[0-9A-Fa-f:]*$ ]] ||
            die "VPN_DNS='$VPN_DNS' non valida: servono indirizzi IP separati da virgole."
    done
}
