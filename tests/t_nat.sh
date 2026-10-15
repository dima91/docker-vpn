#!/bin/bash
# NAT: il traffico dei client esce da qualunque interfaccia del server, non solo eth0.
. "$(dirname "$0")/lib.sh"; cleanup
echo "[nat] immagine=$IMG"
docker network create $P-back >/dev/null
docker run -d --name $P-target --network $P-back "$CLI_IMG" bash -c \
    'while true; do printf "HTTP/1.0 200 OK\r\n\r\nciao-dal-target\n" | nc -l 80 -q 1; done' >/dev/null
TIP=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$P-back\").IPAddress}}" $P-target)
srv_start; srv_ready || { fail "avvio"; docker logs $P-srv 2>&1 | tail -4; }
docker network connect $P-back $P-srv
mng gen-client alice >/dev/null
connects $P-cli alice 30 || fail "connessione del client"
sleep 1
out=$(docker exec $P-cli curl -s --max-time 6 "http://$TIP/")
[ "$out" = ciao-dal-target ] && pass "il client raggiunge un host dietro la seconda interfaccia del server" || fail "host dietro eth1 non raggiungibile (risposta: '${out:-timeout}')"
srv_restart 60 || fail "riavvio"
n=$(docker exec $P-srv iptables -t nat -S POSTROUTING 2>/dev/null | grep -c MASQUERADE)
[ "$n" = 1 ] && pass "dopo il riavvio c'è una sola regola MASQUERADE" || fail "regole MASQUERADE dopo il riavvio: $n"
finish
