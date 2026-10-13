#!/bin/bash
# Revoca dei client: CRL applicata (round 1), revoca ripetibile (#11) e nomi non validi (#12).
. "$(dirname "$0")/lib.sh"; cleanup
echo "[revoke] immagine=$IMG"
srv_start; srv_ready || { fail "avvio"; docker logs $P-srv 2>&1 | tail -4; }
for c in alice bob charlie dave; do mng gen-client $c >/dev/null; done
# revoke-client cancella <nome>.ovpn: per provare a connettersi dopo la revoca serve una copia
for c in alice charlie; do vol "cp /d/$c.ovpn /d/$c-copia.ovpn"; done
revocato() { docker logs $P-srv 2>&1 | grep -q "certificate revoked: CN=$1"; }

echo "[round 1] la revoca è applicata dal server, gli altri client restano connessi"
connects $P-cli alice 30 && pass "alice si connette prima della revoca" || fail "alice prima della revoca"
docker rm -f $P-cli >/dev/null
mng revoke-client alice >/dev/null
refused $P-cli alice-copia 15 && pass "alice revocata è rifiutata" || fail "alice revocata si connette ancora"
revocato alice && pass "il server registra 'certificate revoked' per alice" || fail "nessun 'certificate revoked' per alice nei log"
docker rm -f $P-cli >/dev/null
connects $P-cli bob 30 && pass "bob continua a connettersi" || fail "bob dopo la revoca di alice"
docker rm -f $P-cli >/dev/null

echo "[round 1] una CRL scaduta su disco viene rigenerata all'avvio"
docker rm -f $P-srv >/dev/null
docker run --rm --entrypoint bash -v $P-data:/etc/openvpn "$IMG" -c \
    'cd /etc/openvpn/pki && openssl ca -utf8 -gencrl -config safessl-easyrsa.cnf -crlsec 1 -out crl.pem' >/dev/null 2>&1
sleep 3
srv_start; srv_ready || fail "riavvio con CRL scaduta"
connects $P-cli bob 30 && pass "bob si connette dopo il riavvio con CRL scaduta" || fail "bob con CRL scaduta"
docker rm -f $P-cli >/dev/null
refused $P-cli alice-copia 15 && pass "alice resta revocata dopo il riavvio" || fail "la revoca di alice è andata persa al riavvio"
revocato alice && pass "e il server lo dice nei log" || fail "nessun 'certificate revoked' dopo il riavvio"
docker rm -f $P-cli >/dev/null

echo "[#11] revoca interrotta a metà: ripetendo il comando si completa"
docker exec $P-srv easyrsa --batch --pki-dir=/etc/openvpn/pki revoke charlie >/dev/null 2>&1   # niente gen-crl
out=$(mng revoke-client charlie); rc=$?
[ "$rc" = 0 ] && pass "la seconda esecuzione riesce" || fail "la seconda esecuzione fallisce (codice $rc): $(echo "$out" | tail -1)"
echo "$out" | grep -qi "già revocato" && pass "dice che il certificato era già revocato" || fail "manca 'già revocato'"
docker exec $P-srv test -e /etc/openvpn/charlie.ovpn && fail "charlie.ovpn è rimasto" || pass "il profilo di charlie è stato rimosso"
refused $P-cli charlie-copia 15 && pass "la CRL è stata rigenerata: charlie è rifiutato" || fail "charlie si connette ancora con la CRL non rigenerata"
revocato charlie && pass "il server registra la revoca di charlie" || fail "nessuna revoca di charlie nei log"
docker rm -f $P-cli >/dev/null

echo "[#11] la revoca normale rimuove anche il profilo"
mng revoke-client dave >/dev/null
docker exec $P-srv test -e /etc/openvpn/dave.ovpn && fail "dave.ovpn è rimasto dopo la revoca" || pass "dave.ovpn rimosso"
out=$(mng revoke-client nessuno); rc=$?
{ [ "$rc" != 0 ] && ! echo "$out" | grep -q "Revoked access"; } && pass "un nome inesistente è un errore" || fail "nome inesistente: codice $rc"

echo "[#12] nomi riservati e non validi"
for n in vpn_server ca; do
    out=$(mng revoke-client $n); rc=$?
    [ "$rc" != 0 ] && pass "revoke-client $n rifiutato" || fail "revoke-client $n accettato"
done
docker exec $P-srv test -s /etc/openvpn/pki/issued/vpn_server.crt && pass "il certificato del server è ancora attivo" || fail "il certificato del server è stato revocato"
for n in '../x' 'a b' '-x' '.nascosto' "$(printf 'a%.0s' $(seq 1 65))"; do
    out=$(mng gen-client "$n"); rc=$?
    [ "$rc" != 0 ] && pass "gen-client '${n:0:12}' rifiutato" || fail "gen-client '${n:0:12}' accettato"
done
docker exec $P-srv bash -c 'test ! -e /etc/x.ovpn' && pass "nessun file scritto fuori dalla cartella dati" || fail "creato /etc/x.ovpn"
finish
