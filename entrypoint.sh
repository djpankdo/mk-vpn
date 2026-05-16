#!/bin/bash

# 1. Garante que o diretório e o nó do dispositivo TUN existam para a VPN OpenConnect
mkdir -p /dev/net
if [ ! -c /dev/net/tun ]; then
    mknod /dev/net/tun c 10 200
    chmod 666 /dev/net/tun
fi

# 2. Ativa o encaminhamento de pacotes no kernel (essencial para roteamento)
sysctl -w net.ipv4.ip_forward=1

# 3. Inicia o Microsocks em segundo plano (Porta 1080)
microsocks -p 1080 &

# 4. Inicia o Squid (Proxy HTTP)
service squid start

# 5. Corrige permissões e inicia o FRR (Roteamento Dinâmico)
chown -R frr:frr /etc/frr
if [ -f /usr/lib/frr/frrinit.sh ]; then
    /usr/lib/frr/frrinit.sh start
else
    /usr/lib/frr/frr start
fi

echo "--- Container de Rede Pronto (pankdo/mk-vpn) ---"

# 6. SOLUÇÃO MIKROTIK: Mantém um processo infinito em primeiro plano sem travar CPU
tail -f /dev/null