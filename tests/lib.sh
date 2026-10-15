#!/bin/bash
# shellcheck disable=SC2034
# Funzioni comuni dei test end-to-end di docker-vpn.
#
# Richiedono Docker e /dev/net/tun e si lanciano a mano; in CI girano solo t_manage e
# t_revoke, prima di pubblicare l'immagine. Creano solo risorse con prefisso "vpntest-",
# rimosse a fine test.
#
# Variabili:
#   IMG       immagine sotto test (default: docker-vpn:test, costruita da ../docker)
#   OLD_IMG   immagine precedente alle correzioni, per i test di aggiornamento
#   NO_BUILD  se valorizzata, non ricostruisce IMG

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
IMG=${IMG:-docker-vpn:test}
# Per digest e non per tag: "latest" cambia con la prossima pubblicazione. È l'immagine di marzo 2026,
# prima di crl-verify, del rinnovo del certificato e del resto (Docker usa la copia locale se c'è).
OLD_IMG=${OLD_IMG:-dockerdima/docker-vpn@sha256:46990ffac2a33ac22df59bd91c24523187ab9b03f75c3bbd0478b7a4ba1afcfc}
CLI_IMG=vpntest-client
# Client OpenVPN 2.4 (Ubuntu 20.04, 2.4.12): non conosce block-ipv6. Si costruisce solo se serve.
CLI24_IMG=vpntest-client24
P=vpntest
FAILED=0
export LC_ALL=C

pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAILED=1; }
# check <descrizione> <comando...>: il comando deve riuscire
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }
# check_not <descrizione> <comando...>: il comando deve fallire
check_not() { local d=$1; shift; if "$@" >/dev/null 2>&1; then fail "$d"; else pass "$d"; fi; }
now_ms() { echo $(( $(date +%s%N) / 1000000 )); }

# ensure_image <immagine> <cartella>: costruisce l'immagine se manca o se il Dockerfile
# è cambiato dopo l'ultima costruzione (lo dice l'etichetta con la sua impronta)
ensure_image() {
    local img=$1 dir=$2 sum
    sum=$(sha1sum "$dir/Dockerfile" | cut -d' ' -f1)
    [ "$(docker image inspect -f '{{index .Config.Labels "vpntest.dockerfile"}}' "$img" 2>/dev/null)" = "$sum" ] && return 0
    docker build -q --label "vpntest.dockerfile=$sum" -t "$img" "$dir" >/dev/null
}

# Costruisce le immagini di prova; lib.sh lo chiama da sé in fondo, quindi vale anche per
# un t_*.sh lanciato da solo. run.sh passa NO_BUILD=1 ai test dopo aver costruito IMG una volta.
ensure_images() {
    if [ -z "$NO_BUILD" ] && [ "$IMG" = docker-vpn:test ]; then
        docker build -q -t "$IMG" "$REPO/docker" >/dev/null || { echo "build di $IMG fallita"; exit 2; }
    fi
    ensure_image "$CLI_IMG" "$REPO/tests/client" || { echo "build di $CLI_IMG fallita"; exit 2; }
}

# Rimuove container, volumi e reti del test (mai altro: il prefisso è dedicato)
cleanup() {
    local ids
    ids=$(docker ps -aq --filter "name=$P-");       [ -z "$ids" ] || docker rm -f $ids >/dev/null 2>&1
    ids=$(docker volume ls -q --filter "name=$P-"); [ -z "$ids" ] || docker volume rm $ids >/dev/null 2>&1
    ids=$(docker network ls -q --filter "name=$P-"); [ -z "$ids" ] || docker network rm $ids >/dev/null 2>&1
    return 0
}
trap cleanup EXIT

# Esito finale del singolo test
finish() {
    cleanup
    if [ "$FAILED" = 0 ]; then echo "OK: $(basename "$0")"; else echo "FALLITO: $(basename "$0")"; fi
    exit "$FAILED"
}

net() { docker network inspect $P-net >/dev/null 2>&1 || docker network create $P-net >/dev/null; }

# srv_start [argomenti di docker run...]: server $P-srv sul volume $P-data.
# SRV_IMG sostituisce l'immagine (es. SRV_IMG=$OLD_IMG srv_start).
srv_start() {
    net
    docker run -d --name $P-srv --network $P-net --cap-add NET_ADMIN \
        --sysctl net.ipv4.ip_forward=1 --device /dev/net/tun \
        -e PUBLIC_IP=$P-srv "$@" -v $P-data:/etc/openvpn "${SRV_IMG:-$IMG}" >/dev/null
}

# wait_log <container> <testo> [secondi]: attende il testo nei log. Se il container
# si ferma prima, controlla un'ultima volta e ritorna.
wait_log() {
    local c=$1 pat=$2 t=${3:-180} i=0
    while [ "$i" -lt "$t" ]; do
        docker logs "$c" 2>&1 | grep -q "$pat" && return 0
        if [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" != true ]; then
            sleep 1; docker logs "$c" 2>&1 | grep -q "$pat"; return $?
        fi
        sleep 1; i=$((i + 1))
    done
    return 1
}
srv_ready() { wait_log $P-srv "Initialization Sequence Completed" "${1:-240}"; }

# srv_stopped [secondi]: il container del server deve fermarsi da solo
srv_stopped() {
    local i=0
    while [ "$i" -lt "${1:-30}" ]; do
        [ "$(docker inspect -f '{{.State.Running}}' $P-srv 2>/dev/null)" = true ] || return 0
        sleep 1; i=$((i + 1))
    done
    return 1
}
# srv_restart [secondi]: riavvia $P-srv e attende un NUOVO "Initialization Sequence Completed"
# (i log di un container riavviato contengono ancora quelli dell'avvio precedente)
srv_restart() {
    local n i=0
    n=$(docker logs $P-srv 2>&1 | grep -c "Initialization Sequence Completed")
    docker restart $P-srv >/dev/null
    while [ "$i" -lt "${1:-120}" ]; do
        [ "$(docker logs $P-srv 2>&1 | grep -c "Initialization Sequence Completed")" -gt "$n" ] && return 0
        sleep 1; i=$((i + 1))
    done
    return 1
}
# conf_ha <regex>: server.conf nel volume contiene la riga
conf_ha() { vol "grep -q '$1' /d/server.conf"; }
# riavvia [argomenti di docker run...]: ricrea il server sullo stesso volume e attende l'avvio
riavvia() { docker rm -f $P-srv >/dev/null 2>&1; srv_start "$@"; srv_ready 120; }
srv_exit_code() { docker inspect -f '{{.State.ExitCode}}' $P-srv; }

# vol <comando>: esegue un comando shell con il volume dati montato in /d
vol() { docker run --rm --entrypoint bash -v $P-data:/d "${SRV_IMG:-$IMG}" -c "$*"; }

# mng <argomenti>: manage.sh nel server; MNG_ENV=(-e VAR=valore ...) per variabili extra
MNG_ENV=()
mng() { docker exec "${MNG_ENV[@]}" $P-srv manage.sh "$@" 2>&1; }

# cli_start <nome> <profilo> [argomenti di openvpn...]: client OpenVPN sul volume dati.
# CLI_DOCKER=(--sysctl ...) aggiunge argomenti a docker run.
CLI_DOCKER=()
cli_start() {
    local n=$1 prof=$2; shift 2
    docker rm -f "$n" >/dev/null 2>&1
    docker run -d --name "$n" --network $P-net --cap-add NET_ADMIN --device /dev/net/tun \
        "${CLI_DOCKER[@]}" -v $P-data:/d:ro "$CLI_IMG" openvpn --config "/d/$prof.ovpn" "$@" >/dev/null
}
# connects <nome> <profilo> <secondi> [argomenti di openvpn...]: avvia il client e attende la connessione
connects() {
    local n=$1 prof=$2 t=$3; shift 3
    cli_start "$n" "$prof" "$@" && wait_log "$n" "Initialization Sequence Completed" "$t"
}
# refused <nome> <profilo> <secondi>: il profilo esiste ma il server rifiuta la connessione.
# Senza il controllo sul file, un client senza profilo "verrebbe rifiutato" per il motivo sbagliato.
refused() {
    vol "test -s /d/$2.ovpn" || { echo "    (profilo $2 mancante: la prova non dimostrerebbe nulla)"; return 1; }
    ! connects "$1" "$2" "$3"
}
# profile_serial <profilo>: numero di serie del certificato dentro il profilo
profile_serial() { vol "sed -n '/<cert>/,/<\/cert>/p' /d/$1.ovpn | openssl x509 -noout -serial"; }
# cert_end <file>: scadenza di un certificato nel volume
cert_end() { vol "openssl x509 -in /d/$1 -noout -enddate"; }

# make_legacy: crea il volume $P-legacy con un server inizializzato dall'immagine
# pubblicata prima delle correzioni ($OLD_IMG) e i client alice e bob.
# restore_legacy ne copia il contenuto in un $P-data vuoto, tutte le volte che serve.
make_legacy() {
    docker rm -f $P-srv >/dev/null 2>&1
    docker volume rm $P-data $P-legacy >/dev/null 2>&1
    SRV_IMG=$OLD_IMG srv_start
    srv_ready || { echo "  inizializzazione con $OLD_IMG fallita"; docker logs $P-srv 2>&1 | tail -4; exit 2; }
    docker exec $P-srv manage.sh gen-client alice >/dev/null 2>&1
    docker exec $P-srv manage.sh gen-client bob >/dev/null 2>&1
    docker rm -f $P-srv >/dev/null
    docker run --rm --entrypoint bash -v $P-data:/s:ro -v $P-legacy:/d "$IMG" -c 'cp -a /s/. /d/'
}
restore_legacy() {
    docker rm -f $P-srv >/dev/null 2>&1
    docker volume rm $P-data >/dev/null 2>&1
    docker run --rm --entrypoint bash -v $P-legacy:/s:ro -v $P-data:/d "$IMG" -c 'cp -a /s/. /d/'
}

# Indirizzo del server dentro il tunnel con la subnet predefinita 10.8.0.0
GW=10.8.0.1

ensure_images
