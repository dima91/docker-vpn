#!/bin/bash
# Validità e rinnovo del certificato del server (#1).
. "$(dirname "$0")/lib.sh"; cleanup
echo "[cert] immagine=$IMG"

# Immagine con faketime per simulare il passare del tempo nell'entrypoint
docker build -q -t vpntest-faketime - >/dev/null <<DOCKERFILE || { echo "build faketime fallita"; exit 2; }
FROM $IMG
RUN apt update && apt install -y faketime && rm -rf /var/lib/apt/lists/*
DOCKERFILE
# avanti_nel_tempo <giorni>: esegue l'entrypoint come se fossero passati <giorni> giorni
avanti_nel_tempo() {
    docker run --rm --cap-add NET_ADMIN --entrypoint faketime -v $P-data:/etc/openvpn vpntest-faketime \
        -f "+$1d" entrypoint.sh true 2>&1
}
nove_anni() { vol "openssl x509 -in /d/pki/issued/vpn_server.crt -noout -checkend $((3285 * 86400))"; }

echo "[#1] nuova installazione"
srv_start; srv_ready || fail "avvio"
check "il certificato del server vale più di 9 anni" nove_anni
docker logs $P-srv 2>&1 | grep -q "Certificato del server" && pass "l'avvio riporta la scadenza del certificato" || fail "manca la riga con la scadenza"
cleanup

echo "[#1] volume creato dall'immagine precedente (certificato da 825 giorni)"
make_legacy
fine_prima=$(cert_end pki/issued/vpn_server.crt); ca_prima=$(vol 'sha1sum /d/pki/ca.crt')
echo "    prima: $fine_prima"
check_not "(prima) il certificato vecchio non arriva a 9 anni" nove_anni
srv_start; srv_ready || { fail "avvio sul volume vecchio"; docker logs $P-srv 2>&1 | tail -4; }
echo "    dopo:  $(cert_end pki/issued/vpn_server.crt)"
check "il certificato da 825 giorni è sostituito subito al primo avvio" nove_anni
docker logs $P-srv 2>&1 | grep -qi "Rinnovo" && pass "il log segnala il rinnovo" || fail "manca il messaggio di rinnovo"
[ "$ca_prima" = "$(vol 'sha1sum /d/pki/ca.crt')" ] && pass "la CA non cambia" || fail "la CA è cambiata"
connects $P-cli alice 30 && pass "il profilo emesso prima del rinnovo si connette" || fail "profilo precedente al rinnovo"
seriale=$(vol 'openssl x509 -in /d/pki/issued/vpn_server.crt -noout -serial')
docker rm -f $P-cli >/dev/null; srv_restart 60 || fail "riavvio"
[ "$seriale" = "$(vol 'openssl x509 -in /d/pki/issued/vpn_server.crt -noout -serial')" ] && pass "un secondo avvio non rinnova di nuovo" || fail "rinnovo ripetuto a ogni avvio"

echo "[#1] secondo rinnovo, quando pki/renewed ha già le copie del primo"
docker rm -f $P-srv >/dev/null
vol 'test -s /d/pki/renewed/issued/vpn_server.crt' && pass "(prima) pki/renewed contiene il certificato sostituito dal primo rinnovo" || fail "pki/renewed vuota: la prova non vale"
out=$(avanti_nel_tempo 3630)        # a 20 giorni dalla scadenza
echo "$out" | grep -i "rinnovo\|errore" | sed 's/^/    /'
echo "$out" | grep -qi "non riuscito" && fail "il secondo rinnovo non riesce" || pass "il secondo rinnovo riesce"
[ "$seriale" != "$(vol 'openssl x509 -in /d/pki/issued/vpn_server.crt -noout -serial')" ] && pass "il certificato è stato sostituito di nuovo" || fail "il certificato è lo stesso del primo rinnovo"

echo "[#1] certificato scaduto da 75 giorni"
restore_legacy
avanti_nel_tempo 900 | grep -i "rinnovo\|errore" | sed 's/^/    /'
echo "    dopo:  $(cert_end pki/issued/vpn_server.crt)"
check "il certificato scaduto è rinnovato" nove_anni
check "e verifica contro la CA invariata" docker run --rm --entrypoint faketime -v $P-data:/d vpntest-faketime -f '+900d' openssl verify -CAfile /d/pki/ca.crt /d/pki/issued/vpn_server.crt

echo "[#1] rinnovo che non riesce"
restore_legacy
vol 'touch /d/pki/renewed'     # easy-rsa non può creare la cartella: il rinnovo fallisce con il certificato ancora valido
srv_start
srv_ready && pass "certificato ancora valido: il server parte lo stesso" || { fail "il server non parte con un rinnovo fallito ma certificato valido"; docker logs $P-srv 2>&1 | tail -4; }
docker logs $P-srv 2>&1 | grep -qi "non riuscito" && pass "il rinnovo fallito è segnalato" || fail "manca l'avviso di rinnovo non riuscito"
docker rm -f $P-srv >/dev/null
avanti_nel_tempo 900 >/dev/null; rc=$?
[ "$rc" != 0 ] && pass "certificato scaduto e rinnovo fallito: l'avvio si ferma (codice $rc)" || fail "l'avvio prosegue con un certificato scaduto"
finish
