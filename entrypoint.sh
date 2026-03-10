#!/bin/bash

# 1. Ativa o encaminhamento de pacotes (essencial para VPN/Roteamento)
sysctl -w net.ipv4.ip_forward=1

# 2. Inicia o Microsocks em segundo plano (Porta 1080)
microsocks -p 1080 &

# 3. Inicia o Squid (Proxy HTTP)
service squid start

# 4. Inicia o FRR (Roteamento Dinâmico)
# O FRR precisa que o dono dos arquivos seja o usuário frr
chown -R frr:frr /etc/frr
service frr start

echo "--- Container de Rede Pronto (pankdo/mk-vpn) ---"

# MANTÉM O CONTAINER VIVO: 
# Executa o Bash de forma interativa para o container não fechar
exec /bin/bash