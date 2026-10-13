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
conf_ha() { vol "grep -q '$1' /d/server.conf"; }
riavvia() { docker rm -f $P-srv >/dev/null 2>&1; srv_start "$@"; srv_ready 120; }

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

echo "[#7] client che ignora block-ipv6 (come un client OpenVPN 2.4): nessuna perdita"
cli_start $P-cli alice --proto udp4 --pull-filter ignore block-ipv6; wait_log $P-cli "Initialization Sequence Completed" 30 || fail "connessione"
sleep 1; probe_v6
[ "$V6_DEV" = "dev tun0" ] && pass "l'IPv6 va nel tunnel" || fail "l'IPv6 esce da '$V6_DEV'"
# Un block-ipv6 lato server non fa rispondere il server ai pacchetti dei client (provato, anche con
# server-ipv6): per questi client il traffico è scartato in silenzio. Si garantisce l'assenza di perdite.
echo "$V6_OUT" | grep -qi "bytes from" && fail "l'IPv6 del client è arrivato a destinazione" || pass "nessuna risposta da Internet: l'IPv6 non esce dal tunnel"
docker rm -f $P-cli >/dev/null

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
finish
