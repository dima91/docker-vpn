#!/bin/bash
# manage.sh: permessi dei profili (#3), rigenerazione di un profilo (#4) e controlli
# introdotti nel round 1 (giorni, inizializzazione, indirizzo pubblico).
. "$(dirname "$0")/lib.sh"; cleanup
echo "[manage] immagine=$IMG"
srv_start; srv_ready || { fail "avvio"; docker logs $P-srv 2>&1 | tail -4; }
PROFILO=/etc/openvpn/alice.ovpn

echo "[#3] il profilo contiene la chiave privata: solo root"
mng gen-client alice >/dev/null
[ "$(docker exec $P-srv stat -c %a $PROFILO)" = 600 ] && pass "alice.ovpn ha permessi 600" || fail "alice.ovpn ha permessi $(docker exec $P-srv stat -c %a $PROFILO)"
connects $P-cli alice 30 && pass "il profilo 600 funziona" || fail "connessione con il profilo"
docker rm -f $P-cli >/dev/null

echo "[#4] un profilo esistente si rigenera senza emettere un nuovo certificato"
seriale=$(profile_serial alice); chiave=$(vol "sed -n '/<key>/,/<\/key>/p' /d/alice.ovpn | sha1sum")
out=$(mng gen-client alice); rc=$?
{ [ "$rc" != 0 ] && echo "$out" | grep -q "export-client"; } && pass "gen-client su un nome esistente rifiuta e indica export-client" || fail "gen-client su nome esistente: codice $rc, $(echo "$out" | tail -1)"
[ "$seriale" = "$(profile_serial alice)" ] && pass "il certificato non è cambiato" || fail "il certificato è stato rigenerato"
docker exec $P-srv chmod 644 $PROFILO
MNG_ENV=(-e PUBLIC_IP=vpn.example.org -e VPN_PORT=4444)
out=$(mng export-client alice); rc=$?
[ "$rc" = 0 ] && pass "export-client riesce" || fail "export-client: codice $rc, $(echo "$out" | tail -1)"
MNG_ENV=()
vol "grep -q '^remote vpn.example.org 4444$' /d/alice.ovpn" && pass "il profilo ha il nuovo indirizzo e la nuova porta" || fail "il profilo non è stato aggiornato"
[ "$seriale" = "$(profile_serial alice)" ] && [ "$chiave" = "$(vol "sed -n '/<key>/,/<\/key>/p' /d/alice.ovpn | sha1sum")" ] && pass "stessi certificato e chiave" || fail "certificato o chiave diversi"
[ "$(docker exec $P-srv stat -c %a $PROFILO)" = 600 ] && pass "permessi riportati a 600" || fail "permessi dopo export-client: $(docker exec $P-srv stat -c %a $PROFILO)"
mng export-client alice >/dev/null
connects $P-cli alice 30 && pass "il profilo esportato con le impostazioni del server si connette" || fail "profilo esportato"
docker rm -f $P-cli >/dev/null
out=$(mng export-client nessuno); rc=$?
[ "$rc" != 0 ] && pass "export-client di un nome inesistente è un errore" || fail "export-client nessuno: codice $rc"

echo "[round 1] giorni di validità"
mng gen-client zero 0 >/dev/null
vol 'openssl x509 -in /d/pki/issued/zero.crt -noout -checkend $((3285*86400))' >/dev/null 2>&1 && pass "days=0 emette un certificato di oltre 9 anni" || fail "days=0"
mng gen-client breve 30 >/dev/null
vol 'openssl x509 -in /d/pki/issued/breve.crt -noout -checkend $((29*86400))' >/dev/null 2>&1 &&
    ! vol 'openssl x509 -in /d/pki/issued/breve.crt -noout -checkend $((31*86400))' >/dev/null 2>&1 && pass "days=30 vale 30 giorni" || fail "days=30"
out=$(mng gen-client cattivo abc); rc=$?
{ [ "$rc" != 0 ] && ! docker exec $P-srv test -e /etc/openvpn/pki/issued/cattivo.crt; } && pass "days non numerico rifiutato prima di emettere" || fail "days=abc: codice $rc"

echo "[round 1/#2] nessun profilo mentre l'inizializzazione non è finita"
docker exec $P-srv touch /etc/openvpn/.pki-init
out=$(mng gen-client presto); rc=$?
{ [ "$rc" != 0 ] && ! docker exec $P-srv test -e /etc/openvpn/presto.ovpn; } && pass "rifiutato con l'inizializzazione in corso" || fail "gen-client durante l'inizializzazione: codice $rc"
docker exec $P-srv rm -f /etc/openvpn/.pki-init

echo "[round 1] indirizzo pubblico"
mng gen-client sipuo >/dev/null 2>&1                            # emesso con PUBLIC_IP valorizzato
MNG_ENV=(-e PUBLIC_IP= -e https_proxy=http://127.0.0.1:9)     # ifconfig.me irraggiungibile
out=$(mng gen-client senzaip); rc=$?
{ [ "$rc" != 0 ] && ! docker exec $P-srv test -e /etc/openvpn/senzaip.ovpn && ! docker exec $P-srv test -e /etc/openvpn/pki/issued/senzaip.crt; } &&
    pass "indirizzo non determinabile: errore, nessun certificato, nessun profilo" || fail "indirizzo non determinabile: codice $rc"
out=$(mng revoke-client sipuo); rc=$?
[ "$rc" = 0 ] && pass "revoke-client non dipende dalla rete" || fail "revoke-client senza rete: codice $rc"
MNG_ENV=(-e PUBLIC_IP=)
if docker exec $P-srv curl -fsS --max-time 8 https://ifconfig.me >/dev/null 2>&1; then
    mng gen-client auto >/dev/null
    vol "grep -Eq '^remote [0-9a-fA-F.:]+ 1194$' /d/auto.ovpn" && pass "rilevamento automatico dell'indirizzo" || fail "rilevamento automatico"
else
    echo "  SKIP: ifconfig.me non raggiungibile da qui"
fi
MNG_ENV=()
out=$(mng); rc=$?
{ [ "$rc" = 1 ] && echo "$out" | grep -q "export-client"; } && pass "senza argomenti: uso (con export-client) e codice 1" || fail "uso senza argomenti: codice $rc"
finish
