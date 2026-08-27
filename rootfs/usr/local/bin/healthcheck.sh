#!/bin/bash
# Healthcheck do mk-vpn, no formato que o RouterOS entende: sai com 0 quando
# esta saudavel e 1 quando nao esta, imprimindo numa linha o motivo.
#
# O RouterOS le a instrucao HEALTHCHECK da imagem e expoe o resultado em
# /container/print. Com "stop-on-unhealthy=yes" ele PARA o container quando o
# healthcheck falha o numero de vezes configurado -- para, nao reinicia, o que
# combina com a regra deste projeto de nunca reconectar sozinho.
#
# Cuidado ao mexer aqui: um teste falso-negativo com stop-on-unhealthy ligado
# derruba um tunel que estava funcionando.
set -u

: "${DRY_RUN:=no}"
: "${VPN_IFACE:=tun0}"
: "${VPN_SERVER:=}"
: "${ANYCAST_IP:=192.168.192.168/32}"
: "${ENABLE_SQUID:=yes}"
: "${SQUID_PORT:=3128}"
: "${ENABLE_SOCKS:=yes}"
: "${SOCKS_PORT:=1080}"
: "${ENABLE_FRR:=yes}"

is_yes() { case "${1,,}" in yes|y|true|1|on) return 0 ;; *) return 1 ;; esac; }

problemas=""
anota() { problemas="${problemas}${problemas:+; }$1"; }

porta_escutando() {
    ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"
}

# --- IP anycast do servico -------------------------------------------------
if [ -n "$ANYCAST_IP" ]; then
    if ! ip -4 addr show dev lo 2>/dev/null | grep -qF " ${ANYCAST_IP%%/*}/"; then
        anota "IP anycast ${ANYCAST_IP} ausente da loopback"
    fi
fi

# --- proxies ---------------------------------------------------------------
if is_yes "$ENABLE_SQUID"; then
    pgrep -x squid >/dev/null 2>&1 || anota "squid nao esta rodando"
    porta_escutando "$SQUID_PORT" || anota "nada escutando na porta ${SQUID_PORT}"
fi

if is_yes "$ENABLE_SOCKS"; then
    pgrep -x microsocks >/dev/null 2>&1 || anota "microsocks nao esta rodando"
    porta_escutando "$SOCKS_PORT" || anota "nada escutando na porta ${SOCKS_PORT}"
fi

# --- OSPF ------------------------------------------------------------------
# Sem adjacencia o anycast nao chega ao roteador, entao o container esta
# inutil mesmo que todo o resto esteja de pe.
if is_yes "$ENABLE_FRR"; then
    if ! pgrep -x ospfd >/dev/null 2>&1; then
        anota "ospfd nao esta rodando"
    elif ! timeout 5 vtysh -c 'show ip ospf neighbor' 2>/dev/null | grep -qi 'full'; then
        anota "nenhum vizinho OSPF em estado Full"
    fi
fi

# --- VPN -------------------------------------------------------------------
# Em DRY_RUN a VPN nao sobe de proposito; cobrar isso seria falso negativo.
if is_yes "$DRY_RUN"; then
    :
elif [ -n "$VPN_SERVER" ]; then
    if ! pgrep -x openconnect >/dev/null 2>&1; then
        anota "openconnect nao esta rodando"
    elif ! ip -4 addr show dev "$VPN_IFACE" 2>/dev/null | grep -q 'inet '; then
        # O processo vivo sem endereco na tun significa tunel caido por baixo:
        # e justamente o caso que um "container running" esconderia.
        anota "interface ${VPN_IFACE} sem endereco IPv4"
    fi
fi

# --- veredito --------------------------------------------------------------
if [ -n "$problemas" ]; then
    echo "NAO SAUDAVEL: ${problemas}"
    exit 1
fi

# A mensagem lista o que foi realmente verificado, para nao afirmar que um
# componente desligado por configuracao esta de pe.
ok=""
soma() { ok="${ok}${ok:+, }$1"; }
[ -n "$ANYCAST_IP" ] && soma "anycast ${ANYCAST_IP%%/*}"
is_yes "$ENABLE_SQUID" && soma "squid:${SQUID_PORT}"
is_yes "$ENABLE_SOCKS" && soma "socks:${SOCKS_PORT}"
is_yes "$ENABLE_FRR"   && soma "OSPF adjacente"
if is_yes "$DRY_RUN"; then
    soma "VPN nao conectada (DRY_RUN)"
elif [ -n "$VPN_SERVER" ]; then
    soma "VPN em ${VPN_IFACE}"
fi
echo "saudavel: ${ok:-nada a verificar}"
exit 0
