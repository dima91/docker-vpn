# Client OpenVPN di prova: tunnel, diagnostica di rete e un mini server TCP
FROM debian:12-slim

RUN apt update && \
    apt install -y openvpn iproute2 iputils-ping curl netcat-openbsd && \
    rm -rf /var/lib/apt/lists/*
