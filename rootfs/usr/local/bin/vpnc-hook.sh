#!/bin/bash
# Wrapper do vpnc-script chamado pelo openconnect (--script).
#
# Ele delega tudo ao vpnc-script do Debian (que instala IP, rotas e DNS do
# tunel) e, depois disso, aplica o que o container precisa para funcionar como
# gateway dentro do RouterOS:
#
#   - devolve a rota default ao MikroTik, se VPN_DEFAULT_ROUTE=no;
#   - garante rota de volta para as redes da LAN (senao a resposta a um cliente
#     da LAN sai pelo tunel e o trafego morre por caminho assimetrico);
#   - NAT na saida do tunel;
#   - clamp de MSS.
#
# O openconnect exporta "reason", "TUNDEV", "VPNGATEWAY", "CISCO_SPLIT_INC_*"
# e afins no ambiente; o vpnc-script real consome tudo isso.
set -uo pipefail

REAL_SCRIPT=/usr/share/vpnc-scripts/vpnc-script
RUNDIR=/run/mk-vpn

log() { printf '%s [mk-vpn/hook] %s\n' "$(date -u +%FT%TZ)" "$*"; }

is_yes() { case "${1,,}" in yes|y|true|1|on) return 0 ;; *) return 1 ;; esac; }

: "${VPN_DEFAULT_ROUTE:=no}"
: "${LAN_ROUTES:=}"
: "${ENABLE_NAT:=yes}"
: "${ENABLE_MSS_CLAMP:=yes}"
: "${reason:=unknown}"

DEV="${TUNDEV:-${VPN_IFACE:-tun0}}"

# ---------------------------------------------------------------------------
# Delega ao vpnc-script real
# ---------------------------------------------------------------------------
if [ -x "$REAL_SCRIPT" ]; then
    "$REAL_SCRIPT" "$@"
    RC=$?
else
    log "ERRO: $REAL_SCRIPT nao encontrado (pacote vpnc-scripts ausente)"
    exit 1
fi

# ---------------------------------------------------------------------------
# Regra idempotente de iptables
# ---------------------------------------------------------------------------
ipt_ensure() {
    local table="$1"; shift
    iptables -t "$table" -C "$@" 2>/dev/null || iptables -t "$table" -A "$@"
}

ipt_remove() {
    local table="$1"; shift
    while iptables -t "$table" -C "$@" 2>/dev/null; do
        iptables -t "$table" -D "$@" || break
    done
}

post_connect() {
    log "tunel $DEV no ar (reason=$reason, gateway=${VPNGATEWAY:-?})"

    local orig_gw orig_dev
    orig_gw=$(cat "$RUNDIR/orig-gw" 2>/dev/null)
    orig_dev=$(cat "$RUNDIR/orig-dev" 2>/dev/null)

    # --- rota default -------------------------------------------------------
    if ! is_yes "$VPN_DEFAULT_ROUTE"; then
        # O vpnc-script coloca a default no tunel. Aqui devolvemos ao MikroTik:
        # quem decide o que vai para a VPN e o roteador, com as rotas que o FRR
        # anuncia. As rotas especificas do split tunnel continuam no lugar.
        if ip route show default | grep -q "dev $DEV"; then
            ip route del default dev "$DEV" 2>/dev/null
            log "rota default via $DEV removida (VPN_DEFAULT_ROUTE=no)"
        fi
        if [ -n "$orig_gw" ] && ! ip route show default | grep -q .; then
            ip route add default via "$orig_gw" ${orig_dev:+dev "$orig_dev"} 2>/dev/null \
                && log "rota default restaurada: via $orig_gw dev $orig_dev"
        fi
    else
        log "rota default mantida no tunel (VPN_DEFAULT_ROUTE=yes)"
        # Com full tunnel, sem estas rotas a resposta a um cliente da LAN sai
        # pelo tunel e nada funciona.
        if [ -z "$LAN_ROUTES" ]; then
            log "AVISO: VPN_DEFAULT_ROUTE=yes sem LAN_ROUTES definido - os clientes"
            log "AVISO: da LAN provavelmente nao vao receber resposta."
        fi
    fi

    # --- retorno para a LAN -------------------------------------------------
    if [ -n "$LAN_ROUTES" ] && [ -n "$orig_gw" ]; then
        local net
        for net in $LAN_ROUTES; do
            if ip route replace "$net" via "$orig_gw" ${orig_dev:+dev "$orig_dev"} 2>/dev/null; then
                log "rota de retorno: $net via $orig_gw"
            else
                log "AVISO: falha ao instalar rota de retorno para $net"
            fi
        done
    fi

    # --- NAT ----------------------------------------------------------------
    if is_yes "$ENABLE_NAT"; then
        ipt_ensure nat POSTROUTING -o "$DEV" -j MASQUERADE \
            && log "MASQUERADE ativo na saida de $DEV"
    fi

    # --- MSS ----------------------------------------------------------------
    if is_yes "$ENABLE_MSS_CLAMP"; then
        ipt_ensure mangle FORWARD -o "$DEV" -p tcp --tcp-flags SYN,RST SYN \
            -j TCPMSS --clamp-mss-to-pmtu && log "clamp de MSS ativo em $DEV"
        ipt_ensure mangle OUTPUT -o "$DEV" -p tcp --tcp-flags SYN,RST SYN \
            -j TCPMSS --clamp-mss-to-pmtu
    fi

    # O IP com que o openconnect realmente falou pode nao ser o que resolvemos
    # no boot (DNS round-robin entre concentradores). Sem exclui-lo, a rota host
    # que o vpnc-script acabou de instalar vaza para o OSPF e o MikroTik passa a
    # rotear o concentrador pelo container - que o alcanca pelo MikroTik.
    if [ -n "${VPNGATEWAY:-}" ] && command -v vtysh >/dev/null 2>&1; then
        if vtysh -c 'configure terminal'                  -c "ip prefix-list exclude_VPNGW seq 100 deny ${VPNGATEWAY}/32 le 32"                  >/dev/null 2>&1; then
            log "concentrador $VPNGATEWAY excluido da redistribuicao OSPF"
        else
            log "AVISO: nao consegui excluir $VPNGATEWAY da redistribuicao OSPF"
        fi
    fi

    log "rotas via $DEV:"
    ip route show dev "$DEV" 2>/dev/null | sed 's/^/    /'
    log "tabela de rotas completa:"
    ip route show 2>/dev/null | sed 's/^/    /'
}

post_disconnect() {
    log "tunel $DEV encerrado (reason=$reason); limpando regras"
    is_yes "$ENABLE_NAT" && ipt_remove nat POSTROUTING -o "$DEV" -j MASQUERADE
    if is_yes "$ENABLE_MSS_CLAMP"; then
        ipt_remove mangle FORWARD -o "$DEV" -p tcp --tcp-flags SYN,RST SYN \
            -j TCPMSS --clamp-mss-to-pmtu
        ipt_remove mangle OUTPUT -o "$DEV" -p tcp --tcp-flags SYN,RST SYN \
            -j TCPMSS --clamp-mss-to-pmtu
    fi
}

case "$reason" in
    connect|reconnect) post_connect ;;
    disconnect)        post_disconnect ;;
esac

exit "$RC"
