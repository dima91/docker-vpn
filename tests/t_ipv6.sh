#!/bin/bash
# Blocco dell'IPv6 dei client: rifiuto immediato anche per client che ignorano il
# push (#7), predefinito per volume (#8), valori booleani accettati (#10).
. "$(dirname "$0")/lib.sh"; cleanup
echo "[ipv6] immagine=$IMG"
# rete con IPv6: il client ha un indirizzo IPv6 "vero" sulla sua interfaccia
docker network create --ipv6 --subnet fd00:aaaa::/64 $P-net >/dev/null || { echo "rete IPv6 non creata"; exit 2; }
V6=2606:4700:4700::1111

# probe_v6: instradamento e risposta di un ping IPv6 dal client $P-cli
probe_v6() {
    V6_DEV=$(docker exec $P-cli ip -6 route get $V6 2>/dev/null | grep -o 'dev [a-z0-9]*' | head -1)
    local t0; t0=$(now_ms)
    V6_OUT=$(docker exec $P-cli ping -6 -c1 -W4 $V6 2>&1)
    V6_MS=$(( $(now_ms) - t0 ))
    echo "    instradamento: ${V6_DEV:-nessuno}; ping6: $(echo "$V6_OUT" | grep -im1 'unreach\|bytes from\|packet loss' | cut -c1-70) (${V6_MS} ms)"
}

echo "[#8] volume nuovo: blocco attivo per impostazione predefinita (variabile vuota, come da compose)"
srv_start -e VPN_BLOCK_IPV6= ; srv_ready || { fail "avvio"; docker logs $P-srv 2>&1 | tail -4; }
mng gen-client alice >/dev/null
[ "$(vol 'cat /d/.block-ipv6-default 2>/dev/null')" = 1 ] && pass "predefinito persistito: 1" || fail "predefinito persistito: '$(vol 'cat /d/.block-ipv6-default 2>&1')'"
docker logs $P-srv 2>&1 | grep -qi "IPv6" && pass "l'avvio dichiara la modalità IPv6" || fail "nessuna riga sulla modalità IPv6"
cli_start $P-cli alice --proto udp4; wait_log $P-cli "Initialization Sequence Completed" 30 || fail "connessione"
sleep 1; probe_v6
[ "$V6_DEV" = "dev tun0" ] && pass "l'IPv6 va nel tunnel" || fail "l'IPv6 esce da '$V6_DEV'"
{ echo "$V6_OUT" | grep -qi unreach && [ "$V6_MS" -lt 3000 ]; } && pass "rifiutato subito (client che applica block-ipv6)" || fail "non rifiutato subito"
check "l'IPv4 passa nel tunnel" docker exec $P-cli ping -c1 -W3 $GW

# conta_uscite: pacchetti ICMPv6 echo-request che hanno lasciato eth0 del client, cioè la sua rete
# fuori dal tunnel (vuoto se ip6tables non funziona)
conta_uscite() { docker exec $P-cli ip6tables -nvxL OUTPUT 2>/dev/null | awk '/ipv6-icmp/ {print $1; exit}'; }
# nessuna_perdita: un ping IPv6 verso Internet non esce da eth0. Non basta che manchi la risposta:
# la rete di prova non ha NAT66 e non ne arriverebbe comunque. Si contano i pacchetti in uscita da eth0,
# e un ping verso il gateway della rete di prova (che esce da eth0) dimostra che il contatore li vede.
nessuna_perdita() {
    local prima dopo
    docker exec $P-cli ip6tables -I OUTPUT -o eth0 -p icmpv6 --icmpv6-type echo-request
    prima=$(conta_uscite)
    probe_v6
    dopo=$(conta_uscite)
    [[ "$prima" =~ ^[0-9]+$ && "$dopo" =~ ^[0-9]+$ ]] || { fail "contatore ip6tables non disponibile nel client"; return; }
    [ "$dopo" = "$prima" ] && pass "nessun pacchetto IPv6 esce da eth0: l'IPv6 resta nel tunnel" || fail "$((dopo - prima)) pacchetti IPv6 sono usciti da eth0"
    docker exec $P-cli ping -6 -c1 -W2 fd00:aaaa::1 >/dev/null 2>&1
    [ "$(conta_uscite)" -gt "$dopo" ] && pass "il contatore vede i pacchetti che escono da eth0 (la prova non è vuota)" || fail "il contatore non vede nemmeno un ping fuori dal tunnel"
}

echo "[#7] client che ignora block-ipv6 (simulato con --pull-filter): nessuna perdita"
cli_start $P-cli alice --proto udp4 --pull-filter ignore block-ipv6; wait_log $P-cli "Initialization Sequence Completed" 30 || fail "connessione"
sleep 1
nessuna_perdita
[ "$V6_DEV" = "dev tun0" ] && pass "l'IPv6 va nel tunnel" || fail "l'IPv6 esce da '$V6_DEV'"
docker rm -f $P-cli >/dev/null

echo "[#7] client OpenVPN 2.4 reale: non conosce block-ipv6, si connette lo stesso e non perde"
if ensure_image $CLI24_IMG "$REPO/tests/client24"; then
    CLI_IMG_PREDEFINITA=$CLI_IMG; CLI_IMG=$CLI24_IMG
    cli_start $P-cli alice --proto udp4
    wait_log $P-cli "Initialization Sequence Completed" 30 && pass "il client 2.4 si connette" || fail "il client 2.4 non si connette"
    docker exec $P-cli openvpn --version | head -1 | grep -q "OpenVPN 2\.4" && pass "è un OpenVPN 2.4" || fail "versione di OpenVPN inattesa nell'immagine del client 2.4"
    docker logs $P-cli 2>&1 | grep -q "Unrecognized option.*block-ipv6" && pass "per il client 2.4 block-ipv6 è un'opzione sconosciuta (non applicata)" || fail "il client 2.4 conosce block-ipv6: la prova non vale"
    check "l'IPv4 passa nel tunnel" docker exec $P-cli ping -c1 -W3 $GW
    sleep 1
    nessuna_perdita
    [ "$V6_DEV" = "dev tun0" ] && pass "l'IPv6 va nel tunnel" || fail "l'IPv6 esce da '$V6_DEV'"
    docker rm -f $P-cli >/dev/null
    CLI_IMG=$CLI_IMG_PREDEFINITA
else
    echo "  SKIP: immagine del client 2.4 non costruita (serve la rete per apt)"
fi

echo "[#10] valori che disattivano e attivano il blocco"
for v in 0 false OFF No; do
    riavvia -e VPN_BLOCK_IPV6=$v || fail "avvio con VPN_BLOCK_IPV6=$v"
    conf_ha ifconfig-ipv6 && fail "VPN_BLOCK_IPV6=$v: il blocco è ancora attivo" || pass "VPN_BLOCK_IPV6=$v disattiva il blocco"
done
for v in 1 true ON Yes; do
    riavvia -e VPN_BLOCK_IPV6=$v || fail "avvio con VPN_BLOCK_IPV6=$v"
    conf_ha ifconfig-ipv6 && pass "VPN_BLOCK_IPV6=$v attiva il blocco" || fail "VPN_BLOCK_IPV6=$v: blocco non attivo"
done

echo "[doc] un client con IPv6 disattivato nel kernel"
CLI_DOCKER=(--sysctl net.ipv6.conf.all.disable_ipv6=1)
connects $P-cli alice 20 --proto udp4 && fail "con il blocco attivo il client senza IPv6 si connette" || pass "con il blocco attivo non si connette (limite documentato)"
docker logs $P-cli 2>&1 | grep -q "can't add IPv6" && pass "con l'errore indicato nel README" || fail "errore diverso da quello documentato"
riavvia -e VPN_BLOCK_IPV6=0 || fail "avvio"
connects $P-cli alice 30 --proto udp4 && pass "con VPN_BLOCK_IPV6=0 si connette" || fail "con VPN_BLOCK_IPV6=0 non si connette"
CLI_DOCKER=()
cleanup

echo "[#8] volume creato dall'immagine precedente: il blocco resta disattivato"
docker network create --ipv6 --subnet fd00:aaaa::/64 $P-net >/dev/null
make_legacy
srv_start -e VPN_BLOCK_IPV6= ; srv_ready || { fail "avvio sul volume vecchio"; docker logs $P-srv 2>&1 | tail -4; }
conf_ha ifconfig-ipv6 && fail "volume vecchio: blocco attivo senza averlo chiesto" || pass "volume vecchio: blocco disattivato"
[ "$(vol 'cat /d/.block-ipv6-default 2>/dev/null')" = 0 ] && pass "predefinito persistito: 0" || fail "predefinito persistito: '$(vol 'cat /d/.block-ipv6-default 2>&1')'"
CLI_DOCKER=(--sysctl net.ipv6.conf.all.disable_ipv6=1)
connects $P-cli alice 30 --proto udp4 && pass "il client senza IPv6 con il profilo vecchio si connette ancora" || fail "profilo vecchio dopo l'aggiornamento"
CLI_DOCKER=(); docker rm -f $P-cli >/dev/null
riavvia -e VPN_BLOCK_IPV6= || fail "secondo avvio"
conf_ha ifconfig-ipv6 && fail "al secondo avvio il predefinito è passato ad attivo" || pass "il predefinito non cambia al secondo avvio"
riavvia -e VPN_BLOCK_IPV6=1 || fail "avvio con VPN_BLOCK_IPV6=1"
conf_ha ifconfig-ipv6 && pass "VPN_BLOCK_IPV6=1 lo attiva esplicitamente" || fail "VPN_BLOCK_IPV6=1 non attiva il blocco"
riavvia -e VPN_BLOCK_IPV6= || fail "avvio senza variabile"
conf_ha ifconfig-ipv6 && fail "senza variabile il blocco è rimasto attivo" || pass "togliendo la variabile si torna al predefinito del volume"

echo "[#8] volume vecchio senza server.conf né file del predefinito (vecchio modo di rigenerare la configurazione)"
docker rm -f $P-srv >/dev/null
vol 'rm -f /d/server.conf /d/.block-ipv6-default'
riavvia -e VPN_BLOCK_IPV6= || { fail "avvio senza server.conf"; docker logs $P-srv 2>&1 | tail -4; }
[ "$(vol 'cat /d/.block-ipv6-default 2>/dev/null')" = 0 ] && pass "la PKI già creata basta per riconoscere il volume vecchio: predefinito 0" || fail "predefinito persistito: '$(vol 'cat /d/.block-ipv6-default 2>&1')'"
conf_ha ifconfig-ipv6 && fail "senza server.conf il volume vecchio è passato al blocco attivo" || pass "il blocco resta disattivato"

echo "[#8] file del predefinito con contenuto non valido: errore chiaro, nessun valore indovinato"
docker rm -f $P-srv >/dev/null
vol 'printf "" > /d/.block-ipv6-default'
srv_start -e VPN_BLOCK_IPV6=
if srv_stopped 60; then
    [ "$(srv_exit_code)" != 0 ] && pass "il container si ferma con codice $(srv_exit_code)" || fail "il container è uscito con codice 0"
else
    fail "il container non si è fermato"
fi
docker logs $P-srv 2>&1 | grep -q "block-ipv6-default" && pass "il messaggio nomina il file" || fail "il messaggio non nomina il file"
docker rm -f $P-srv >/dev/null
riavvia -e VPN_BLOCK_IPV6=0 || fail "con VPN_BLOCK_IPV6 impostato il file non serve"
finish
