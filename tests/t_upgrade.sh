#!/bin/bash
# Aggiornamento: volume e profili creati dall'immagine precedente con l'immagine nuova.
. "$(dirname "$0")/lib.sh"; cleanup
echo "[upgrade] vecchia=$OLD_IMG nuova=$IMG"
make_legacy
ca=$(vol 'sha1sum /d/pki/ca.crt')
[ "$(vol 'stat -c %a /d/alice.ovpn /d/bob.ovpn' | sort -u)" = 644 ] && pass "(prima) i profili dell'immagine vecchia sono leggibili da tutti (644)" || fail "(prima) permessi dei profili vecchi: $(vol 'stat -c %a /d/alice.ovpn /d/bob.ovpn' | tr '\n' ' ')"
srv_start; srv_ready || { fail "avvio della nuova immagine sul volume vecchio"; docker logs $P-srv 2>&1 | tail -6; }
[ "$ca" = "$(vol 'sha1sum /d/pki/ca.crt')" ] && pass "la CA non è toccata" || fail "la CA è cambiata"
[ "$(vol 'stat -c %a /d/alice.ovpn /d/bob.ovpn' | sort -u)" = 600 ] && pass "i profili vecchi, con la chiave privata del client, sono portati a 600" || fail "permessi dei profili dopo l'aggiornamento: $(vol 'stat -c %a /d/alice.ovpn /d/bob.ovpn' | tr '\n' ' ')"
docker logs $P-srv 2>&1 | grep -q "profili .ovpn leggibili da altri utenti" && pass "l'avvio segnala la correzione dei permessi" || fail "nessun avviso sui permessi"
vol 'grep -q crl-verify /d/server.conf && ls /d/server.conf.bak.* >/dev/null 2>&1 && ! grep -q crl-verify /d/server.conf.bak.*' && pass "server.conf nuovo, quello vecchio salvato in .bak.<data>" || fail "salvataggio di server.conf"
connects $P-cli alice 30 && pass "un profilo emesso dall'immagine vecchia si connette" || fail "profilo vecchio"
docker rm -f $P-cli >/dev/null
vol 'cp /d/alice.ovpn /d/alice-copia.ovpn'     # revoke-client cancella alice.ovpn: la copia serve alla prova
mng revoke-client alice >/dev/null
refused $P-cli alice-copia 15 && pass "la revoca è applicata sul volume aggiornato" || fail "la revoca non è applicata sul volume aggiornato"
docker logs $P-srv 2>&1 | grep -q "certificate revoked: CN=alice" && pass "il server registra la revoca di alice" || fail "nessuna revoca di alice nei log"
docker rm -f $P-cli >/dev/null
connects $P-cli bob 30 && pass "bob (emesso prima del rinnovo del certificato del server) si connette" || fail "bob dopo l'aggiornamento"
docker rm -f $P-cli $P-srv >/dev/null
echo "[upgrade] modalità TCP su un server nuovo"
docker volume rm $P-data >/dev/null
srv_start -e VPN_PROTO=tcp -e VPN_PORT=1195; srv_ready || { fail "avvio TCP"; docker logs $P-srv 2>&1 | tail -4; }
mng gen-client carol >/dev/null
vol "grep -Eq '^proto tcp$' /d/carol.ovpn && grep -Eq '^remote $P-srv 1195$' /d/carol.ovpn" && pass "il profilo ha proto tcp e porta 1195" || fail "profilo TCP"
connects $P-cli carol 30 && pass "il client TCP si connette" || fail "client TCP"
finish
