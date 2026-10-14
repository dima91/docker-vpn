#!/bin/bash
# Esegue i test end-to-end (tutti, o quelli indicati) e controlla che non restino
# risorse "vpntest-*". Uso: tests/run.sh [t_init t_cert ...]
# Ogni PKI nuova genera i parametri DH: l'intera suite richiede diversi minuti.
cd "$(dirname "$0")" || exit 2
. ./lib.sh   # costruisce anche le immagini di prova

cleanup

if [ "$#" -gt 0 ]; then
    TESTS=()
    for t in "$@"; do TESTS+=("${t%.sh}.sh"); done
else
    TESTS=(t_*.sh)
fi

RESULT=0
for t in "${TESTS[@]}"; do
    echo "=== $t"
    NO_BUILD=1 ./"$t" || RESULT=1
done

echo "=== risorse rimaste"
LEFT=$(docker ps -a --format '{{.Names}}' | grep "^$P-"; docker volume ls -q | grep "^$P-"; docker network ls --format '{{.Name}}' | grep "^$P-")
if [ -n "$LEFT" ]; then echo "$LEFT"; RESULT=1; else echo "nessuna"; fi

[ "$RESULT" = 0 ] && echo "TUTTI I TEST OK" || echo "ALCUNI TEST FALLITI"
exit "$RESULT"
