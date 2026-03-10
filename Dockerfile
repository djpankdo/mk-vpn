# Usando Debian Slim para economizar espaço no flash do MikroTik
FROM debian:stable-slim

# Evita diálogos durante a instalação
ENV DEBIAN_FRONTEND=noninteractive

# Instalação de todos os pacotes solicitados
RUN apt-get update && apt-get install -y --no-install-recommends \
    frr \
    openconnect \
    iputils-ping \
    traceroute \
    iptables \
    iproute2 \
    procps \
    microsocks \
    squid \
    curl \
    vim-tiny \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Criar diretórios necessários para os serviços
RUN mkdir -p /var/run/frr /var/run/sshd

# Expor portas comuns (SOCKS5: 1080, Squid: 3128, OpenConnect: 443)
EXPOSE 1080 3128

# COPIAR O SCRIPT E DAR PERMISSÃO
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /app

# DEFINIR O ENTRYPOINT
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
