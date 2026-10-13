#!/bin/bash
# Generazione di server.conf: personalizzazioni che sopravvivono (#9), DNS configurabile,
# protocollo normalizzato.
. "$(dirname "$0")/lib.sh"; cleanup
echo "[config] immagine=$IMG"
conf_ha() { vol "grep -q '$1' /d/server.conf"; }
riavvia() { docker rm -f $P-srv >/dev/null 2>&1; srv_start "$@"; srv_ready 120; }

echo "[#9] DNS predefinito e configurabile"
srv_start; srv_ready || { fail "avvio"; docker logs $P-srv 2>&1 | tail -4; }
[ "$(vol "grep -c 'dhcp-option DNS' /d/server.conf")" = 1 ] && conf_ha 'dhcp-option DNS 1.1.1.1' && pass "predefinito: solo 1.1.1.1" || fail "DNS predefinito"
riavvia -e VPN_DNS=9.9.9.9,8.8.8.8 -e VPN_PROTO=UDP || fail "avvio con VPN_DNS"
conf_ha 'dhcp-option DNS 9.9.9.9' && conf_ha 'dhcp-option DNS 8.8.8.8' && pass "VPN_DNS: un push per ogni indirizzo" || fail "VPN_DNS non applicato"
conf_ha 'dhcp-option DNS 1.1.1.1' && fail "1.1.1.1 è rimasto con VPN_DNS impostato" || pass "1.1.1.1 non compare più"
conf_ha '^proto udp$' && pass "VPN_PROTO=UDP normalizzato in udp" || fail "VPN_PROTO=UDP non normalizzato"

echo "[#9] server.custom.conf sopravvive alla riscrittura"
mng gen-client alice >/dev/null
vol 'printf "%s\n" "push \"route 192.168.77.0 255.255.255.0\"" "client-to-client" > /d/server.custom.conf'
riavvia || fail "avvio con server.custom.conf"
conf_ha 'route 192.168.77.0' && conf_ha '^client-to-client$' && pass "le righe personalizzate sono in server.conf" || fail "server.custom.conf ignorato"
connects $P-cli alice 30 && pass "con la configurazione personalizzata un client si connette" || fail "connessione con server.custom.conf"
docker exec $P-cli ip route | grep -q 192.168.77.0 && pass "il client riceve la rotta spinta" || fail "rotta personalizzata non ricevuta"
docker rm -f $P-cli >/dev/null
riavvia || fail "secondo avvio"
conf_ha 'route 192.168.77.0' && pass "dopo un altro riavvio le righe ci sono ancora" || fail "righe perse al riavvio"
vol 'rm /d/server.custom.conf'; riavvia || fail "avvio senza file"
conf_ha 'route 192.168.77.0' && fail "togliendo il file la rotta è rimasta" || pass "togliendo il file le righe spariscono"
cleanup

echo "[#9] server.conf modificato a mano (volume dell'immagine precedente)"
make_legacy
srv_start; srv_ready || fail "avvio sul volume vecchio"
n=$(vol 'ls /d/server.conf.bak.* 2>/dev/null | wc -l')
[ "$n" = 1 ] && pass "il vecchio server.conf è salvato come server.conf.bak.<data>" || fail "copie di backup: $n"
docker logs $P-srv 2>&1 | grep -q "server.custom.conf" && pass "il log indica dove mettere le personalizzazioni" || fail "il log non nomina server.custom.conf"
primo=$(vol 'ls /d/server.conf.bak.* | sort | head -1')
vol "sed -i '/^# Generato/d' /d/server.conf; echo '# seconda modifica' >> /d/server.conf"
sleep 1.2
riavvia || fail "riavvio dopo la seconda modifica"
n=$(vol 'ls /d/server.conf.bak.* 2>/dev/null | wc -l')
[ "$n" = 2 ] && pass "una seconda modifica a mano crea una seconda copia" || fail "copie di backup: $n"
vol "grep -q 'redirect-gateway' $primo && ! grep -q 'seconda modifica' $primo" && pass "la prima copia non è stata sovrascritta" || fail "la prima copia è stata sovrascritta"
finish
