# Client OpenVPN di prova: tunnel, diagnostica di rete (anche ip6tables, per contare i pacchetti) e un mini server TCP
FROM debian:12-slim

RUN apt update && \
    apt install -y openvpn iproute2 iputils-ping iptables curl netcat-openbsd && \
    rm -rf /var/lib/apt/lists/*
