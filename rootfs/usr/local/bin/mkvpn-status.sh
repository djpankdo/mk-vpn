#!/bin/bash
# Diagnóstico rápido de dentro do container:
#   /container/shell <n>  →  mkvpn-status.sh
set -u

sec() { printf '\n===== %s =====\n' "$*"; }

sec "processos"
ps -eo pid,comm,args --no-headers | grep -vE '^\s*[0-9]+ (ps|grep)' | sed 's/^/  /'

sec "interfaces"
ip -br addr show

sec "rotas"
ip route show

sec "iptables nat"
iptables -t nat -S 2>/dev/null

sec "iptables mangle"
iptables -t mangle -S 2>/dev/null

sec "ip_forward"
cat /proc/sys/net/ipv4/ip_forward 2>/dev/null

sec "resolv.conf"
cat /etc/resolv.conf 2>/dev/null

sec "gateway original salvo"
printf '  gw=%s dev=%s\n' "$(cat /run/mk-vpn/orig-gw 2>/dev/null)" \
                          "$(cat /run/mk-vpn/orig-dev 2>/dev/null)"

sec "roteamento dinâmico (FRR)"
if command -v vtysh >/dev/null 2>&1; then
    case "${ROUTING_PROTOCOL:-ospf}" in
        bgp)
            vtysh -c 'show bgp summary'      2>&1 | sed 's/^/  /'
            vtysh -c 'show bgp ipv4 unicast' 2>&1 | head -40 | sed 's/^/  /'
            ;;
        *)
            vtysh -c 'show ip ospf neighbor'  2>&1 | sed 's/^/  /'
            vtysh -c 'show ip ospf interface' 2>&1 | head -30 | sed 's/^/  /'
            vtysh -c 'show ip ospf database'  2>&1 | head -30 | sed 's/^/  /'
            ;;
    esac
    echo "  --- rotas na visao do zebra ---"
    vtysh -c 'show ip route' 2>&1 | head -40 | sed 's/^/  /'
else
    echo "  vtysh indisponível"
fi

sec "portas em escuta"
ss -lntp 2>/dev/null || netstat -lntp 2>/dev/null
