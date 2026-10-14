#!/bin/bash
set -e

# shellcheck source=common.sh
. /usr/local/lib/vpn-common.sh

validate_env

# CMD usa server.conf con un percorso relativo: così segue anche un OPENVPN diverso
cd "$OPENVPN"

INTESTAZIONE='# Generato da entrypoint.sh'
CERT="$PKI/issued/vpn_server.crt"

# --- Predefinito di VPN_BLOCK_IPV6 per questo volume --------------------------

# Il predefinito è 1 per un volume nuovo e 0 per un volume creato dalle versioni
# precedenti, così l'aggiornamento non cambia il comportamento (vedi più sotto).
# Si decide al primo avvio, prima di qualunque operazione lenta, e si memorizza
# subito: un'interruzione durante la creazione della PKI non può cambiarlo.
STATO_IPV6="$OPENVPN/.block-ipv6-default"

# Scrittura atomica: un file a metà non può restare
memorizza_ipv6() {
    echo "$1" > "$STATO_IPV6.tmp"
    mv "$STATO_IPV6.tmp" "$STATO_IPV6"
}

if [ ! -f "$STATO_IPV6" ]; then
    # Un volume delle versioni precedenti si riconosce dalla PKI già completa o da un
    # server.conf non generato qui. La PKI basta da sola: cancellare server.conf per
    # rigenerarlo (il vecchio modo di ripartire) non deve far passare il volume a "nuovo".
    if { [ -e "$PKI" ] && [ ! -e "$PKI_MARKER" ]; } ||
       { [ -f "$OPENVPN/server.conf" ] && ! grep -q "^$INTESTAZIONE" "$OPENVPN/server.conf"; }; then
        memorizza_ipv6 0
    else
        memorizza_ipv6 1
    fi
fi

# --- Profili ------------------------------------------------------------------

# Un profilo contiene la chiave privata del client e la chiave TLS. manage.sh li scrive
# con permessi 600, ma quelli emessi dalle versioni precedenti sono leggibili da tutti:
# in una cartella montata dall'host li leggerebbe qualunque utente locale.
PROFILI_APERTI=$(find "$OPENVPN" -maxdepth 1 -name '*.ovpn' -perm /077 -exec chmod go-rwx {} + -print | wc -l)
if [ "$PROFILI_APERTI" -gt 0 ]; then
    echo "--- $PROFILI_APERTI profili .ovpn leggibili da altri utenti: portati a permessi 600 ---"
fi

# --- PKI ---------------------------------------------------------------------

# Un avvio interrotto durante la creazione della PKI lascia il marcatore. Finché
# esiste manage.sh non emette nulla, quindi nella PKI non c'è niente da conservare.
if [ -e "$PKI_MARKER" ]; then
    echo "--- Inizializzazione precedente interrotta: ricomincio da zero ---"
    rm -rf "$PKI"
fi

if [ ! -e "$PKI" ]; then
    echo "--- Creo la PKI ---"
    touch "$PKI_MARKER"
    ersa init-pki
    ersa build-ca nopass
    ersa gen-dh
    # Il certificato del server dura quanto la CA invece degli 825 giorni predefiniti
    ersa --days="$MAX_DAYS" build-server-full vpn_server nopass
    # Chiave TLS-Auth (Sintassi OpenVPN 2.6+)
    openvpn --genkey secret "$PKI/ta.key"
    rm -f "$PKI_MARKER"
fi

# Una PKI senza marcatore è considerata completa e non viene mai cancellata
# (init-pki in batch non chiede conferma). Se manca qualcosa, decide chi la gestisce.
for f in ca.crt dh.pem issued/vpn_server.crt private/vpn_server.key ta.key; do
    [ -s "$PKI/$f" ] ||
        die "PKI incompleta in $PKI ($f mancante o vuoto), probabilmente per un'inizializzazione interrotta di una versione precedente. Rimuovi la cartella pki per ricrearla: i profili già emessi non funzioneranno più."
done

# Certificato del server: rinnovato quando mancano meno di 30 giorni alla scadenza,
# oppure se è uno di quelli da 825 giorni emessi dalle versioni precedenti (altrimenti
# un container sempre acceso lo vedrebbe scadere senza riavvii). easy-rsa consente il
# rinnovo solo dentro la finestra --renew-days.
giorni_certificato() {
    local da a
    da=$(date -d "$(openssl x509 -in "$CERT" -noout -startdate | cut -d= -f2)" +%s)
    a=$(date -d "$(openssl x509 -in "$CERT" -noout -enddate | cut -d= -f2)" +%s)
    echo $(( (a - da) / 86400 ))
}
# Un certificato emesso da questa versione dura MAX_DAYS: con meno di MAX_DAYS - 365
# giorni di validità totale è uno delle versioni precedenti (825 giorni)
VALIDITA_MINIMA=$((MAX_DAYS - 365))
if ! openssl x509 -in "$CERT" -noout -checkend $((30 * 86400)) >/dev/null || [ "$(giorni_certificato)" -lt "$VALIDITA_MINIMA" ]; then
    echo "--- Rinnovo il certificato del server ---"
    # easy-rsa sposta il certificato sostituito in pki/renewed e al rinnovo successivo si
    # rifiuta di procedere finché le copie della volta prima sono lì ("conflicting file
    # exists"): il certificato scaduto non si potrebbe più rinnovare. Non servono a nessuno.
    rm -f "$PKI/renewed/issued/vpn_server.crt" "$PKI/renewed/private/vpn_server.key" "$PKI/renewed/reqs/vpn_server.req"
    if ! ersa --days="$MAX_DAYS" --renew-days="$MAX_DAYS" renew vpn_server nopass; then
        echo "Errore: rinnovo del certificato del server non riuscito." >&2
        openssl x509 -in "$CERT" -noout -checkend 0 >/dev/null ||
            die "il certificato del server è scaduto e non si riesce a rinnovarlo: nessun client potrebbe connettersi."
    fi
fi
echo "--- Certificato del server valido fino al $(openssl x509 -in "$CERT" -noout -enddate | cut -d= -f2) ---"

# Con crl-verify una CRL scaduta fa rifiutare tutti i client, quindi viene
# rigenerata a ogni avvio (la validità è EASYRSA_CRL_DAYS, vedi Dockerfile).
ersa gen-crl

# --- server.conf -------------------------------------------------------------

# server.conf viene riscritto a ogni avvio, così porta, protocollo e subnet seguono
# sempre le variabili d'ambiente (e la regola di NAT più sotto). Un file non generato
# da questo script viene conservato prima di essere sostituito.
if [ -f "$OPENVPN/server.conf" ] && ! grep -q "^$INTESTAZIONE" "$OPENVPN/server.conf"; then
    COPIA="$OPENVPN/server.conf.bak.$(date +%Y%m%d%H%M%S)"
    cp "$OPENVPN/server.conf" "$COPIA"
    echo "--- server.conf non generato da questo script: copiato in $COPIA. Le personalizzazioni vanno in $OPENVPN/server.custom.conf ---"
fi

# Il tunnel è solo IPv4: senza altro, un client dual-stack continua a usare l'IPv6
# della sua rete fuori dalla VPN. Lo si instrada nel tunnel, dove il client stesso lo
# rifiuta (block-ipv6 spinto, OpenVPN 2.5+). Un client più vecchio ignora l'opzione:
# il suo IPv6 entra nel tunnel e il server lo scarta senza risposta (nessuna perdita,
# solo timeout). Un block-ipv6 nella configurazione del server non cambia il risultato
# (provato anche con server-ipv6): non riguarda il traffico che arriva dai client.
# Chi ha IPv6 disattivato nel kernel non può configurare l'indirizzo IPv6 spinto
# e non si connette: per questo c'è VPN_BLOCK_IPV6=0.
# Un client OpenVPN 2.4 che non conosce block-ipv6 registra "Options error" e si
# connette lo stesso (provato con 2.4.12; GCM richiede comunque almeno la 2.4).
# Il predefinito del volume è stato deciso e memorizzato all'inizio.
if [ -n "${VPN_BLOCK_IPV6:-}" ]; then
    BLOCCA_IPV6=$(to_bool "$VPN_BLOCK_IPV6"); ORIGINE="VPN_BLOCK_IPV6"
else
    BLOCCA_IPV6=$(<"$STATO_IPV6"); ORIGINE="predefinito del volume"
    [[ "$BLOCCA_IPV6" =~ ^[01]$ ]] ||
        die "$STATO_IPV6 contiene '$BLOCCA_IPV6': serve 0 o 1. Correggi il file o rimuovilo (senza il file, un volume con la PKI già creata parte senza il blocco)."
fi
if [ "$BLOCCA_IPV6" = 1 ]; then
    echo "--- IPv6 dei client: bloccato ($ORIGINE). VPN_BLOCK_IPV6=0 lo disattiva ---"
    REDIRECT="def1 ipv6 bypass-dhcp"
    CONF_IPV6='push "ifconfig-ipv6 fd15:53b6:dead::2/64 fd15:53b6:dead::1"
push "block-ipv6"'
else
    echo "--- IPv6 dei client: non bloccato ($ORIGINE). VPN_BLOCK_IPV6=1 lo blocca ---"
    REDIRECT="def1 bypass-dhcp"
    CONF_IPV6=""
fi

IFS=, read -ra DNS <<< "$VPN_DNS"
CONF_DNS=""
for d in "${DNS[@]}"; do
    CONF_DNS+="push \"dhcp-option DNS $d\""$'\n'
done

echo "--- Scrivo server.conf ---"
cat <<EOF > "$OPENVPN/server.conf"
$INTESTAZIONE a ogni avvio: le modifiche manuali vengono sovrascritte (usa server.custom.conf).
port $VPN_PORT
proto $VPN_PROTO
dev tun
ca $PKI/ca.crt
cert $CERT
key $PKI/private/vpn_server.key
dh $PKI/dh.pem
tls-auth $PKI/ta.key 0
crl-verify $PKI/crl.pem
server $VPN_SUBNET 255.255.255.0
push "redirect-gateway $REDIRECT"
$CONF_IPV6
$CONF_DNS
keepalive 10 120
cipher AES-256-GCM
persist-key
persist-tun
verb 3
EOF

# Righe aggiuntive dell'utente: sopravvivono alla riscrittura di server.conf
if [ -f "$OPENVPN/server.custom.conf" ]; then
    { echo; echo "# --- $OPENVPN/server.custom.conf ---"; cat "$OPENVPN/server.custom.conf"; } >> "$OPENVPN/server.conf"
fi

# --- Routing -----------------------------------------------------------------

# NAT per tutto ciò che esce dalla subnet VPN, qualunque sia l'interfaccia di uscita.
# Vale per la rete bridge del container, dove le regole spariscono con il container.
# Con network_mode: host finirebbero nelle tabelle dell'host e non verrebbero mai
# rimosse (e il FORWARD dell'host potrebbe comunque scartare il traffico): non è supportato.
NAT_RULE=(POSTROUTING -s "$VPN_SUBNET/24" ! -d "$VPN_SUBNET/24" -j MASQUERADE)
iptables -t nat -C "${NAT_RULE[@]}" 2>/dev/null || iptables -t nat -A "${NAT_RULE[@]}"

exec "$@"
