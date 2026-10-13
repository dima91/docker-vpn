#!/bin/bash
# Avvio e inizializzazione della PKI: init interrotto (#2), OPENVPN diverso dal
# predefinito (#13), validazione delle variabili d'ambiente (#12).
. "$(dirname "$0")/lib.sh"; cleanup
echo "[init] immagine=$IMG"

# Una PKI coerente: il certificato del server è firmato dalla CA e corrisponde alla sua chiave
pki_coerente() {
    vol 'openssl verify -CAfile /d/pki/ca.crt /d/pki/issued/vpn_server.crt &&
         [ "$(openssl x509 -in /d/pki/issued/vpn_server.crt -noout -pubkey | sha1sum)" = "$(openssl pkey -in /d/pki/private/vpn_server.key -pubout | sha1sum)" ]'
}

echo "[#2] avvio ucciso durante la generazione dei parametri DH"
srv_start
for _ in $(seq 1 100); do docker exec $P-srv test -s /etc/openvpn/pki/ca.crt 2>/dev/null && break; sleep 0.2; done
docker kill $P-srv >/dev/null; docker rm -f $P-srv >/dev/null
srv_start
srv_ready && pass "il riavvio completa l'inizializzazione" || { fail "il riavvio non completa l'inizializzazione"; docker logs $P-srv 2>&1 | tail -4; }
check "PKI coerente dopo la ripresa" pki_coerente
mng gen-client alice >/dev/null
connects $P-cli alice 30 && pass "un client emesso dopo la ripresa si connette" || fail "client dopo la ripresa"
cleanup

echo "[#2] avvio interrotto tra la richiesta e la firma del certificato del server"
net
docker run --rm --entrypoint bash -v $P-data:/etc/openvpn "$IMG" -c '
    touch /etc/openvpn/.pki-init
    E="easyrsa --batch --pki-dir=/etc/openvpn/pki"
    $E init-pki; $E build-ca nopass; $E gen-req vpn_server nopass' >/dev/null 2>&1
srv_start
srv_ready && pass "stato parziale con marcatore: l'init riparte da zero e termina" || { fail "stato parziale con marcatore"; docker logs $P-srv 2>&1 | tail -4; }
check "PKI coerente" pki_coerente
cleanup

echo "[#2] PKI incompleta senza marcatore (init di una versione precedente): errore chiaro, nessuna cancellazione"
net
docker run --rm --entrypoint bash -v $P-data:/etc/openvpn "$IMG" -c '
    E="easyrsa --batch --pki-dir=/etc/openvpn/pki"; $E init-pki; $E build-ca nopass' >/dev/null 2>&1
ca1=$(vol 'sha1sum /d/pki/ca.crt')
srv_start
if srv_stopped 60; then
    [ "$(srv_exit_code)" != 0 ] && pass "il container si ferma con codice $(srv_exit_code)" || fail "il container è uscito con codice 0"
else
    fail "il container non si è fermato"
fi
docker logs $P-srv 2>&1 | grep -qi "PKI incompleta" && pass "il messaggio dice che la PKI è incompleta" || fail "manca il messaggio 'PKI incompleta'"
[ "$ca1" = "$(vol 'sha1sum /d/pki/ca.crt')" ] && pass "la PKI esistente non è stata toccata" || fail "la CA è stata modificata o cancellata"
cleanup

echo "[#13] OPENVPN diverso dal predefinito"
net
docker run -d --name $P-srv --network $P-net --cap-add NET_ADMIN --sysctl net.ipv4.ip_forward=1 \
    --device /dev/net/tun -e OPENVPN=/data -e PUBLIC_IP=$P-srv -v $P-data:/data "$IMG" >/dev/null
srv_ready && pass "il server parte con OPENVPN=/data" || { fail "il server non parte con OPENVPN=/data"; docker logs $P-srv 2>&1 | tail -4; }
check "server.conf e PKI stanno in /data" vol 'test -s /d/server.conf && test -s /d/pki/ca.crt'
cleanup

echo "[#12] variabili d'ambiente non valide: errore immediato che nomina la variabile"
rifiutata() {
    local assegnazione=$1 var=${1%%=*} out rc
    out=$(timeout 40 docker run --rm --cap-add NET_ADMIN -e "$assegnazione" "$IMG" true 2>&1); rc=$?
    if [ "$rc" = 1 ] && echo "$out" | grep -q "$var"; then pass "$assegnazione rifiutata"
    else fail "$assegnazione: codice $rc, messaggio: $(echo "$out" | tail -1)"; fi
}
for a in VPN_SUBNET=10.8.0.0/24 VPN_SUBNET=10.8.0.1 VPN_SUBNET=999.1.1.0 VPN_PORT=0 VPN_PORT=70000 \
         VPN_PORT=abc VPN_PROTO=icmp VPN_BLOCK_IPV6=maybe VPN_DNS=non-un-ip; do
    rifiutata "$a"
done
finish
