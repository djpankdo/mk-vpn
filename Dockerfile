# mk-vpn - OpenConnect + FRR + proxies para rodar dentro do RouterOS (MikroTik)
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
      vim-tiny \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# Remove as configuracoes que os pacotes do Debian instalam. O entrypoint decide
# "veio de mount?" pela simples existencia do arquivo - deixar o default do
# pacote no lugar faz o container achar que o usuario forneceu configuracao e
# nunca gerar a sua, subindo o Squid com "deny all" e o FRR sem OSPF.
RUN rm -f /etc/squid/squid.conf /etc/frr/frr.conf

# Diretorios de runtime. /etc/frr e /etc/squid podem ser sobrescritos por mount
# do RouterOS; os templates ficam em /etc/mk-vpn e so sao aplicados se o destino
# ainda nao tiver configuracao propria.
RUN mkdir -p /run/mk-vpn /run/frr /var/log/mk-vpn \
 && chown frr:frr /run/frr

COPY rootfs/ /

RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/vpnc-hook.sh \
             /usr/local/bin/mkvpn-status.sh \
             /usr/local/bin/healthcheck.sh

# Informativo apenas: o RouterOS ignora EXPOSE.
EXPOSE 1080/tcp 3128/tcp 179/tcp

# O RouterOS le esta instrucao da imagem e expoe o resultado em
# /container/print. O start-period da tempo de o OSPF fechar adjacencia e
# de a VPN autenticar antes da primeira cobranca.
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh

STOPSIGNAL SIGTERM

WORKDIR /run/mk-vpn

# O entrypoint roda como PID 1, sem tini. O tini nao instala handlers de
# sinal: ele bloqueia tudo e usa sigtimedwait, entao o SigCgt do PID 1 fica
# zerado. O RouterOS le isso, conclui que o SIGTERM "nao seria capturado" e
# vai direto ao SIGKILL, sem nunca entregar o sinal ao nosso trap -- o que
# inviabiliza a parada graciosa. Com o bash em PID 1 o trap aparece no
# SigCgt e o RouterOS entrega o SIGTERM normalmente.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
