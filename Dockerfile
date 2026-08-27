# mk-vpn — OpenConnect + FRR + proxies para rodar dentro do RouterOS (MikroTik)
# Alvo: linux/arm64 (RB5009, CCR2004, hAP ax...) com storage externo.
#
# Tag fixa em vez de "stable-slim": "stable" muda de release sozinha e quebra
# o build sem aviso. Suba a tag conscientemente quando quiser.
FROM debian:trixie-slim

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      openconnect \
      vpnc-scripts \
      frr \
      frr-pythontools \
      squid \
      microsocks \
      iptables \
      iproute2 \
      iputils-ping \
      traceroute \
      mtr-tiny \
      tcpdump \
      dnsutils \
      openssl \
      ca-certificates \
      curl \
      procps \
      gettext-base \
      tini \
      vim-tiny \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# Diretórios de runtime. /etc/frr e /etc/squid podem ser sobrescritos por mount
# do RouterOS; os templates ficam em /etc/mk-vpn e só são aplicados se o destino
# ainda não tiver configuração própria.
RUN mkdir -p /run/mk-vpn /run/frr /var/log/mk-vpn \
 && chown frr:frr /run/frr

COPY rootfs/ /

RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/vpnc-hook.sh \
             /usr/local/bin/mkvpn-status.sh

# Informativo apenas: o RouterOS ignora EXPOSE.
EXPOSE 1080/tcp 3128/tcp 179/tcp

STOPSIGNAL SIGTERM

WORKDIR /run/mk-vpn

ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/entrypoint.sh"]
