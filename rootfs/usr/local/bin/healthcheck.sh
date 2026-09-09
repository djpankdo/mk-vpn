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

# Lista de IPv4 separados por espaco. Sem valor, ou sem nenhum IPv4 valido, o
# teste fica desabilitado -- nunca tratado como falha: derrubar um tunel que
# funciona por causa de um erro de digitacao seria pior do que nao testar.
: "${VPN_USER:=}"
: "${CONFIG_PARAM:=}"
# Minutos de ociosidade que o concentrador tolera antes de derrubar a sessao.
# Nao ha como descobrir sozinho: o openconnect interpreta o cabecalho
# X-CSTP-Idle-Timeout mas nao o imprime na verbosidade padrao. Vazio = a
# telemetria publica "expira_se_ocioso" como desconhecido, em vez de inventar.
: "${VPN_IDLE_MIN:=}"

: "${VPN_PING_TARGETS:=}"
: "${VPN_PING_COUNT:=2}"
: "${VPN_PING_DEADLINE:=2}"

is_yes() { case "${1,,}" in yes|y|true|1|on) return 0 ;; *) return 1 ;; esac; }

# O mesmo decodificador do entrypoint. Sem isto, um modulo desligado por
# CONFIG_PARAM continuaria sendo cobrado aqui, o container ficaria "unhealthy"
# e, com stop-on-unhealthy, o RouterOS o pararia: desligar um modulo derrubaria
# o container inteiro. O aviso de valor malformado nao e impresso aqui - o
# entrypoint ja o registra no boot, e a saida do healthcheck e uma linha so.
. /usr/local/lib/mk-vpn/config_param.sh
cp_decode
cp_off socks && ENABLE_SOCKS=no
cp_off squid && ENABLE_SQUID=no
cp_off frr   && ENABLE_FRR=no

problemas=""
anota() { problemas="${problemas}${problemas:+; }$1"; }

ipv4_valido() {
    local ip="$1" o
    case "$ip" in ''|*[!0-9.]*|*..*|.*|*.) return 1 ;; esac
    local IFS=.
    set -- $ip
    [ $# -eq 4 ] || return 1
    for o in "$@"; do
        case "$o" in ''|*[!0-9]*) return 1 ;; esac
        [ "${#o}" -le 3 ] && [ "$o" -le 255 ] || return 1
    done
    return 0
}

porta_escutando() {
    ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"
}

# --- IP anycast do servico -------------------------------------------------
if [ -n "$ANYCAST_IP" ] && ! cp_off anycast; then
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
if is_yes "$DRY_RUN" || cp_off vpn; then
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

# --- trafego real pelo tunel -----------------------------------------------
# Dois motivos, e nenhum deles e coberto pelas verificacoes acima. Primeiro,
# provar que o tunel passa pacote de verdade, e nao apenas que a interface tem
# endereco. Segundo, gerar trafego periodico: o concentrador derruba a sessao
# por inatividade, e o healthcheck rodando a cada 30s serve de keepalive.
#
# Escolha alvos que so existam do lado corporativo; um IP alcancavel pela WAN
# responderia mesmo com o tunel morto e o teste nao valeria nada.
ping_estado=""
if is_yes "$DRY_RUN" || cp_off vpn || cp_off hc_ping; then
    ping_estado=""
elif [ -n "$VPN_PING_TARGETS" ]; then
    alvos=""
    for alvo in $VPN_PING_TARGETS; do
        ipv4_valido "$alvo" && alvos="$alvos $alvo"
    done
    if [ -z "$alvos" ]; then
        ping_estado="ping desabilitado (VPN_PING_TARGETS sem IPv4 valido)"
    else
        # Basta um alvo responder: o que se testa e o tunel, nao a saude de
        # cada host. Para no primeiro sucesso para caber no timeout do
        # healthcheck.
        for alvo in $alvos; do
            if ping -A -n -q -c "$VPN_PING_COUNT" -w "$VPN_PING_DEADLINE" "$alvo" >/dev/null 2>&1; then
                ping_estado="ping ok em $alvo"
                break
            fi
        done
        if [ -z "$ping_estado" ]; then
            anota "nenhum alvo respondeu ao ping pelo tunel ($alvos )"
        fi
    fi
fi

# --- telemetria para o ramo roteadores/ ------------------------------------
# Uma linha JSON no stdout, que um script do roteador repassa ao MQTT
# acrescentando quem e o roteador e o container -- os dois unicos dados que o
# container nao tem como saber sobre si mesmo.
#
# A saida deste script NAO vai para o log do container: o RouterOS a captura na
# propriedade "healthcheck-status" do proprio container, que o script do
# roteador le direto. Isso e melhor que passar pelo log por tres motivos -- nao
# consome o buffer de 1000 linhas, nao corre risco de truncamento de mensagem, e
# o valor lido e sempre o da ultima execucao, nunca um residuo antigo.
#
# Por isso a linha e emitida em TODA execucao: como o status e sobrescrito a
# cada vez, nao ha acumulo a economizar.
if true; then
    estado=desconectado
    if is_yes "$DRY_RUN"; then
        estado=dry-run
    elif cp_off vpn; then
        estado=vpn-desativada
    elif [ -z "$VPN_SERVER" ]; then
        estado=sem-servidor
    elif ip -4 addr show dev "$VPN_IFACE" 2>/dev/null | grep -q 'inet '; then
        estado=conectado
    fi

    tun_ip=$(ip -4 -br addr show dev "$VPN_IFACE" 2>/dev/null | awk '{print $3}' | cut -d/ -f1)
    veth_ip=$(ip -4 -br addr show 2>/dev/null | awk '$1!="lo" && $1!="'"$VPN_IFACE"'" && $3 ~ /\// {print $3; exit}' | cut -d/ -f1)
    gw=$(cat /run/mk-vpn/vpn-gw 2>/dev/null)
    desde=$(cat /run/mk-vpn/vpn-desde 2>/dev/null)
    rotas=$(cat /run/mk-vpn/vpn-rotas 2>/dev/null)
    [ -n "$rotas" ] || rotas=0
    vizinhos=0
    if is_yes "$ENABLE_FRR" && command -v vtysh >/dev/null 2>&1; then
        vizinhos=$(timeout 5 vtysh -c 'show ip ospf neighbor' 2>/dev/null | grep -ci 'full')
    fi
    expira=""
    if [ "$estado" = conectado ] && [ -n "$VPN_IDLE_MIN" ]; then
        expira=$(date -u -d "+${VPN_IDLE_MIN} minutes" +%FT%TZ 2>/dev/null)
    fi
    veredito=saudavel
    [ -n "$problemas" ] && veredito="$problemas"

    printf 'MKVPN {"st":"%s","user":"%s","srv":"%s","gw":"%s","tun":"%s","veth":"%s","desde":"%s","expira_se_ocioso":"%s","rotas":%s,"ospf":%s,"ping":"%s","host":"%s","cfg":"%s","diag":"%s","ts":"%s"}
'        "$estado" "$VPN_USER" "$VPN_SERVER" "$gw" "$tun_ip" "$veth_ip" "$desde" "$expira"         "$rotas" "$vizinhos" "${ping_estado:-}" "$(hostname)" "$CONFIG_PARAM"         "$(printf '%s' "$veredito" | tr '"' "'" | cut -c1-80)" "$(date -u +%FT%TZ)"
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
[ -n "$ANYCAST_IP" ] && ! cp_off anycast && soma "anycast ${ANYCAST_IP%%/*}"
is_yes "$ENABLE_SQUID" && soma "squid:${SQUID_PORT}"
is_yes "$ENABLE_SOCKS" && soma "socks:${SOCKS_PORT}"
is_yes "$ENABLE_FRR"   && soma "OSPF adjacente"
if cp_off vpn; then
    soma "VPN desativada (CONFIG_PARAM)"
elif is_yes "$DRY_RUN"; then
    soma "VPN nao conectada (DRY_RUN)"
elif [ -n "$VPN_SERVER" ]; then
    soma "VPN em ${VPN_IFACE}"
fi
[ -n "$ping_estado" ] && soma "$ping_estado"
echo "saudavel: ${ok:-nada a verificar}"
exit 0
