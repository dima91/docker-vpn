# Client OpenVPN 2.4 (2.4.12) per provare un client che non conosce le opzioni spinte
# dal server più recenti, come block-ipv6 (2.5+). Come tests/client, più il contatore IPv6.
FROM ubuntu:20.04

RUN apt update && \
    apt install -y openvpn iproute2 iputils-ping iptables && \
    rm -rf /var/lib/apt/lists/*
