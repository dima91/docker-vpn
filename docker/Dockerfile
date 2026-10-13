FROM debian:12-slim

RUN apt update && apt upgrade -y && \
    apt install -y openvpn easy-rsa iptables procps curl && \
    ln -s /usr/share/easy-rsa/easyrsa /usr/local/bin/easyrsa && \
    rm -rf /var/lib/apt/lists/*

ENV OPENVPN=/etc/openvpn
# Validità della CRL: quella predefinita di easy-rsa (180 giorni) bloccherebbe
# tutti i client alla scadenza. Vale per entrypoint.sh, manage.sh e docker exec.
ENV EASYRSA_CRL_DAYS=3650

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY manage.sh /usr/local/bin/manage.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/manage.sh /usr/local/bin/easyrsa

WORKDIR /etc/openvpn
ENTRYPOINT ["entrypoint.sh"]
CMD ["openvpn", "--config", "server.conf"]
