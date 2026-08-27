#!/bin/bash
# mk-vpn — entrypoint do container OpenConnect para RouterOS/MikroTik.
#
# Sem "set -e": uma falha isolada (ex.: sysctl bloqueado pelo RouterOS) não deve
# derrubar o container inteiro. Cada passo trata o próprio erro.
set -uo pipefail

RUNDIR=/run/mk-vpn
SHUTDOWN_FLAG="$RUNDIR/shutdown"
mkdir -p "$RUNDIR"
rm -f "$SHUTDOWN_FLAG"

log()  { printf '%s [mk-vpn] %s\n' "$(date -u +%FT%TZ)" "$*"; }
warn() { log "AVISO: $*"; }
err()  { log "ERRO: $*"; }
shutting_down() { [ -e "$SHUTDOWN_FLAG" ]; }

# ---------------------------------------------------------------------------
# Variáveis reconhecidas (tudo tem default; nada é obrigatório exceto o par
# VPN_SERVER/VPN_USER para que a VPN seja tentada).
# ---------------------------------------------------------------------------
: "${VPN_SERVER:=}"            # host, host:porta ou URL do concentrador
: "${VPN_USER:=}"
: "${VPN_PASS:=}"              # senha em texto puro
: "${VPN_PASS_B64:=}"          # senha em base64 (evita brigar com o parser do RouterOS)
: "${VPN_PASS_FILE:=}"         # caminho de arquivo (mount) contendo a senha
: "${VPN_GROUP:=}"             # --authgroup
: "${VPN_PROTOCOL:=}"          # anyconnect | gp | nc | pulse | f5 | fortinet | array
: "${VPN_2FA:=}"               # atalho para main:secondary_password=<valor>
: "${VPN_FORM_ENTRIES:=}"      # "form:campo=valor;form:campo=valor"
: "${VPN_FINGERPRINT:=}"       # pin-sha256:... (recomendado)
: "${VPN_INSECURE:=no}"        # yes = descobre e confia no cert apresentado (perigoso)
: "${VPN_IFACE:=tun0}"
: "${VPN_MTU:=}"
: "${VPN_EXTRA_ARGS:=}"        # argumentos crus repassados ao openconnect
: "${VPN_DEFAULT_ROUTE:=no}"   # yes = túnel captura a rota default do container
: "${VPN_DEBUG:=no}"           # yes = --dump-http-traffic (CUIDADO: loga credenciais)

# O concentrador BLOQUEIA a conta após duas falhas de autenticação. Por isso não
# existe reconexão automática aqui, e por isso existe o DRY_RUN: ele faz o boot
# inteiro e só registra no log o comando que seria executado, sem gastar uma
# tentativa. Use-o sempre que mexer em algo que afete a linha do openconnect.
: "${DRY_RUN:=no}"

: "${LAN_ROUTES:=}"            # prefixos que devem voltar pelo gateway do MikroTik
: "${ENABLE_NAT:=yes}"         # MASQUERADE na saída do túnel
: "${ENABLE_MSS_CLAMP:=yes}"   # clamp de MSS (evita travar HTTPS por MTU)

: "${ENABLE_SOCKS:=yes}"
: "${SOCKS_PORT:=1080}"
: "${SOCKS_BIND:=0.0.0.0}"
: "${SOCKS_USER:=}"
: "${SOCKS_PASS:=}"

: "${ENABLE_SQUID:=yes}"
: "${SQUID_PORT:=3128}"
: "${PROXY_ALLOW:=10.0.0.0/8 172.16.0.0/12 192.168.0.0/16}"

: "${ENABLE_FRR:=yes}"
: "${ROUTING_PROTOCOL:=ospf}"  # ospf | bgp | none
: "${ROUTER_ID:=}"             # default: IP da interface voltada ao MikroTik
: "${UPLINK_IFACE:=}"          # default: interface da rota default (o veth)
: "${ADVERTISE_DEFAULT:=no}"   # yes = anuncia 0.0.0.0/0 ao MikroTik

# OSPF (padrão)
: "${OSPF_AREA:=0.0.0.0}"
: "${OSPF_COST:=}"
: "${OSPF_HELLO:=}"
: "${OSPF_DEAD:=}"
: "${OSPF_MD5_KEY:=}"          # se definido, ativa autenticação message-digest
: "${OSPF_MD5_KEY_ID:=1}"

# BGP (usado apenas com ROUTING_PROTOCOL=bgp)
: "${BGP_AS:=}"                # ASN local do container
: "${BGP_PEER:=}"              # IP do MikroTik no veth
: "${BGP_PEER_AS:=}"

KNOWN_VARS="VPN_SERVER VPN_USER VPN_PASS VPN_PASS_B64 VPN_PASS_FILE VPN_GROUP
VPN_PROTOCOL VPN_2FA VPN_FORM_ENTRIES VPN_FINGERPRINT VPN_INSECURE VPN_IFACE
VPN_MTU VPN_EXTRA_ARGS VPN_DEFAULT_ROUTE VPN_DEBUG DRY_RUN LAN_ROUTES ENABLE_NAT
ENABLE_MSS_CLAMP ENABLE_SOCKS SOCKS_PORT SOCKS_BIND SOCKS_USER SOCKS_PASS
ENABLE_SQUID SQUID_PORT PROXY_ALLOW ENABLE_FRR ROUTING_PROTOCOL ROUTER_ID
UPLINK_IFACE ADVERTISE_DEFAULT OSPF_AREA OSPF_COST OSPF_HELLO OSPF_DEAD
OSPF_MD5_KEY OSPF_MD5_KEY_ID BGP_AS BGP_PEER BGP_PEER_AS"

SECRET_VARS=" VPN_PASS VPN_PASS_B64 VPN_PASS_FILE VPN_2FA VPN_FORM_ENTRIES SOCKS_PASS OSPF_MD5_KEY "

is_yes() { case "${1,,}" in yes|y|true|1|on) return 0 ;; *) return 1 ;; esac; }

# ---------------------------------------------------------------------------
# 0. Diagnóstico do ambiente — o RouterOS silencia erros de envlist, então
#    imprimir o que chegou (e o que não foi reconhecido) economiza horas.
# ---------------------------------------------------------------------------
dump_env() {
    log "================ mk-vpn: ambiente recebido ================"
    local v val
    for v in $KNOWN_VARS; do
        val="${!v}"
        if [ -z "$val" ]; then
            printf '    %-22s (vazio)\n' "$v"
        elif [[ "$SECRET_VARS" == *" $v "* ]]; then
            printf '    %-22s <definido: %d caracteres>\n' "$v" "${#val}"
        else
            printf '    %-22s %s\n' "$v" "$val"
        fi
    done

    # Variáveis com cara de configuração nossa que não reconhecemos: quase
    # sempre erro de digitação no "/container/envs" do RouterOS.
    # KNOWN_VARS é multilinha; sem normalizar, os nomes no fim de cada linha
    # não casariam com o teste de substring abaixo.
    local unknown="" known
    known=" $(echo $KNOWN_VARS) "
    for v in $(compgen -e | grep -E '^(VPN_|BGP_|SOCKS_|SQUID_|PROXY_|LAN_|ENABLE_|OSPF_)'); do
        [[ "$known" == *" $v "* ]] || unknown="$unknown $v"
    done
    [ -n "$unknown" ] && warn "variáveis NÃO reconhecidas (erro de digitação no envlist?):$unknown"

    log "interfaces: $(ip -br addr show 2>/dev/null | tr '\n' '|')"
    log "rota default: $(ip route show default 2>/dev/null | head -1)"
    log "==========================================================="
}

# ---------------------------------------------------------------------------
# 1. Nó TUN
# ---------------------------------------------------------------------------
setup_tun() {
    if [ -c /dev/net/tun ]; then
        log "/dev/net/tun já existe"
        return 0
    fi
    mkdir -p /dev/net
    if mknod /dev/net/tun c 10 200 2>/dev/null; then
        chmod 600 /dev/net/tun
        log "/dev/net/tun criado"
    else
        err "não foi possível criar /dev/net/tun — o container precisa de CAP_MKNOD."
        err "No RouterOS isso normalmente significa que falta o mount de /dev/net"
        err "ou que o container não está rodando com privilégios suficientes."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# 2. Encaminhamento de pacotes
# ---------------------------------------------------------------------------
setup_forwarding() {
    if sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1; then
        log "net.ipv4.ip_forward=1"
    else
        warn "não foi possível escrever em net.ipv4.ip_forward (/proc/sys read-only)."
        warn "valor atual: $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo '?')"
    fi
    sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# 3. Senha
# ---------------------------------------------------------------------------
resolve_password() {
    REAL_PASS=""
    if [ -n "$VPN_PASS_FILE" ]; then
        if [ -r "$VPN_PASS_FILE" ]; then
            REAL_PASS=$(head -n1 "$VPN_PASS_FILE")
            log "senha lida de $VPN_PASS_FILE (${#REAL_PASS} caracteres)"
        else
            err "VPN_PASS_FILE=$VPN_PASS_FILE não existe ou não é legível"
            return 1
        fi
    elif [ -n "$VPN_PASS_B64" ]; then
        if ! REAL_PASS=$(printf '%s' "$VPN_PASS_B64" | base64 -d 2>/dev/null); then
            err "VPN_PASS_B64 não é base64 válido"
            return 1
        fi
        # Um base64 gerado com "echo" carrega \n no fim; é o erro mais comum aqui.
        REAL_PASS=${REAL_PASS%$'\n'}
        log "senha decodificada de VPN_PASS_B64 (${#REAL_PASS} caracteres)"
    elif [ -n "$VPN_PASS" ]; then
        REAL_PASS="$VPN_PASS"
        log "senha lida de VPN_PASS (${#REAL_PASS} caracteres)"
    else
        err "nenhuma senha informada (use VPN_PASS, VPN_PASS_B64 ou VPN_PASS_FILE)"
        return 1
    fi
    [ -n "$REAL_PASS" ] || { err "a senha resolvida ficou vazia"; return 1; }
}

# ---------------------------------------------------------------------------
# 4. Fingerprint do servidor
#    Calculado com openssl (determinístico) em vez de raspar o stderr do
#    openconnect. Só roda quando VPN_INSECURE=yes.
# ---------------------------------------------------------------------------
vpn_hostport() {
    local s="$VPN_SERVER"
    s="${s#*://}"      # tira o esquema
    s="${s%%/*}"       # tira o path
    case "$s" in
        *:*) printf '%s' "$s" ;;
        *)   printf '%s:443' "$s" ;;
    esac
}

probe_fingerprint() {
    local hp host port pin
    hp=$(vpn_hostport); host="${hp%:*}"; port="${hp##*:}"
    log "sondando $host:$port para calcular o pin do certificado..."
    pin=$(openssl s_client -connect "$host:$port" -servername "$host" </dev/null 2>/dev/null \
          | openssl x509 -pubkey -noout 2>/dev/null \
          | openssl pkey -pubin -outform der 2>/dev/null \
          | openssl dgst -sha256 -binary 2>/dev/null \
          | openssl base64 2>/dev/null)
    if [ -n "$pin" ]; then
        printf 'pin-sha256:%s' "$pin"
    fi
}

# ---------------------------------------------------------------------------
# 5. Supervisão dos serviços auxiliares
# ---------------------------------------------------------------------------
supervise() {
    local name="$1"; shift
    (
        while :; do
            shutting_down && exit 0
            log "iniciando $name"
            "$@"
            rc=$?
            shutting_down && exit 0
            warn "$name terminou (rc=$rc); reiniciando em 5s"
            sleep 5
        done
    ) &
    log "supervisor de $name: pid $!"
}

# ---------------------------------------------------------------------------
# 6. Squid — sem squid.conf próprio, o default upstream é
#    "allow localhost; deny all", ou seja, nega toda a LAN.
# ---------------------------------------------------------------------------
start_squid() {
    is_yes "$ENABLE_SQUID" || { log "Squid desabilitado (ENABLE_SQUID=$ENABLE_SQUID)"; return 0; }

    # Configuração efêmera: regerada a todo boot. O mesmo container roda em
    # redes diferentes, então nada aqui pode ficar preso a um IP da rede
    # anterior — e o root-dir do RouterOS persiste entre reinícios.
    local nets="$PROXY_ALLOW"
    local n
    for n in $(ip -4 route show scope link proto kernel 2>/dev/null | awk '{print $1}'); do
        case " $nets " in *" $n "*) ;; *) nets="$nets $n" ;; esac
    done

    {
        echo "# mk-vpn managed — regerado a cada boot; não edite dentro do container."
        for net in $nets; do
            echo "acl mkvpn_clients src $net"
        done
        cat /etc/mk-vpn/squid.conf.tmpl
        echo "http_port $SQUID_PORT"
    } > /etc/squid/squid.conf
    log "squid.conf gerado (porta $SQUID_PORT, redes permitidas:$(printf ' %s' $nets))"

    if ! squid -k parse -f /etc/squid/squid.conf >/dev/null 2>&1; then
        err "squid.conf inválido:"
        squid -k parse -f /etc/squid/squid.conf 2>&1 | sed 's/^/    /'
        return 1
    fi

    # -N: primeiro plano (nada de "service squid start", que depende do init).
    # -d1: log no stderr, que vira o log do container no RouterOS.
    supervise squid squid -N -d1 -f /etc/squid/squid.conf
}

# ---------------------------------------------------------------------------
# 7. microsocks
# ---------------------------------------------------------------------------
start_socks() {
    is_yes "$ENABLE_SOCKS" || { log "SOCKS desabilitado (ENABLE_SOCKS=$ENABLE_SOCKS)"; return 0; }
    local args
    args=(-i "$SOCKS_BIND" -p "$SOCKS_PORT")
    if [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASS" ]; then
        args+=(-u "$SOCKS_USER" -P "$SOCKS_PASS")
        log "microsocks em ${SOCKS_BIND}:${SOCKS_PORT} com autenticação"
    else
        warn "microsocks em ${SOCKS_BIND}:${SOCKS_PORT} SEM autenticação — qualquer host"
        warn "que alcance essa porta entra na rede corporativa. Use SOCKS_USER/SOCKS_PASS"
        warn "ou restrinja o acesso no firewall do MikroTik."
    fi
    supervise microsocks microsocks "${args[@]}"
}

# ---------------------------------------------------------------------------
# 8a. Geração do frr.conf
#     A política de saída nega 0.0.0.0/0 por padrão: anunciar a default ao
#     MikroTik sequestraria a saída do roteador inteiro.
# ---------------------------------------------------------------------------
prefix_policy() {
    if is_yes "$ADVERTISE_DEFAULT"; then
        echo "ip prefix-list MKVPN-OUT seq 10 permit 0.0.0.0/0 le 32"
    else
        echo "ip prefix-list MKVPN-OUT seq 5 deny 0.0.0.0/0"
        echo "ip prefix-list MKVPN-OUT seq 10 permit 0.0.0.0/0 le 32"
    fi
}

write_frr_ospf() {
    local iface="$1" rid="$2" ifextra="" deforig="" ridline=""
    [ -n "$rid" ] && ridline=" ospf router-id ${rid}"

    if [ -n "$OSPF_MD5_KEY" ]; then
        ifextra="${ifextra}
 ip ospf authentication message-digest
 ip ospf message-digest-key ${OSPF_MD5_KEY_ID} md5 ${OSPF_MD5_KEY}"
    fi
    [ -n "$OSPF_COST" ]  && ifextra="${ifextra}
 ip ospf cost ${OSPF_COST}"
    [ -n "$OSPF_HELLO" ] && ifextra="${ifextra}
 ip ospf hello-interval ${OSPF_HELLO}"
    [ -n "$OSPF_DEAD" ]  && ifextra="${ifextra}
 ip ospf dead-interval ${OSPF_DEAD}"
    is_yes "$ADVERTISE_DEFAULT" && deforig=" default-information originate"

    # "passive-interface default" + "no passive-interface <veth>" mantém o OSPF
    # falando só com o MikroTik: nada de tentar adjacência pelo túnel.
    # As rotas do split tunnel entram no zebra como "kernel" (quem as instala é
    # o vpnc-script), por isso "redistribute kernel".
    cat > /etc/frr/frr.conf <<FRREOF
! mk-vpn managed — REGERADO A CADA BOOT a partir das variáveis OSPF_*.
! Editar este arquivo dentro do container não adianta: ele é sobrescrito.
frr defaults traditional
hostname mk-vpn
log stdout informational
service integrated-vtysh-config
!
interface ${iface}
 ip ospf area ${OSPF_AREA}${ifextra}
!
router ospf
${ridline}
 passive-interface default
 no passive-interface ${iface}
 redistribute kernel route-map MKVPN-OUT
 redistribute connected route-map MKVPN-OUT
${deforig}
!
$(prefix_policy)
!
route-map MKVPN-OUT permit 10
 match ip address prefix-list MKVPN-OUT
!
line vty
!
FRREOF
    sed -i '/^$/d' /etc/frr/frr.conf
}

write_frr_bgp() {
    local rid="$1" ridline=""
    [ -n "$rid" ] && ridline=" bgp router-id ${rid}"

    # "no bgp ebgp-requires-policy": sem isso o FRR 8+ não anuncia nada em eBGP.
    cat > /etc/frr/frr.conf <<FRREOF
! mk-vpn managed — REGERADO A CADA BOOT a partir das variáveis BGP_*.
! Editar este arquivo dentro do container não adianta: ele é sobrescrito.
frr defaults traditional
hostname mk-vpn
log stdout informational
service integrated-vtysh-config
!
router bgp ${BGP_AS}
${ridline}
 no bgp ebgp-requires-policy
 neighbor ${BGP_PEER} remote-as ${BGP_PEER_AS}
 neighbor ${BGP_PEER} description mikrotik
 !
 address-family ipv4 unicast
  redistribute kernel
  redistribute connected
  neighbor ${BGP_PEER} activate
  neighbor ${BGP_PEER} route-map MKVPN-OUT out
  neighbor ${BGP_PEER} soft-reconfiguration inbound
 exit-address-family
!
$(prefix_policy)
!
route-map MKVPN-OUT permit 10
 match ip address prefix-list MKVPN-OUT
!
line vty
!
FRREOF
    sed -i '/^$/d' /etc/frr/frr.conf
}

# ---------------------------------------------------------------------------
# 8. FRR — redistribui para o MikroTik as rotas que o vpnc-script instalar.
# ---------------------------------------------------------------------------
start_frr() {
    is_yes "$ENABLE_FRR" || { log "FRR desabilitado (ENABLE_FRR=$ENABLE_FRR)"; return 0; }

    # O RouterOS persiste o filesystem do container no root-dir, então /run NÃO
    # é tmpfs: pid files e sockets da execução anterior sobrevivem ao restart.
    # Sem limpar, o FRR falha com "Can't create pid lock file" e "Address
    # already in use", o watchfrr fica preso em "Waiting for children to finish
    # applying config..." e o entrypoint nunca chega a conectar a VPN.
    rm -rf /run/frr/* /var/tmp/frr/* 2>/dev/null
    mkdir -p /run/frr /var/tmp/frr
    chown frr:frr /run/frr /var/tmp/frr 2>/dev/null
    rm -f /run/squid.pid 2>/dev/null

    local rid iface
    iface="$UPLINK_IFACE"
    if [ -z "$iface" ]; then
        # A interface do veth é a que carrega a rota default antes de a VPN
        # subir — é por ela que falamos com o MikroTik. Detectar pela rota, e
        # não por IP, mantém isto válido em qualquer rede.
        iface=$(ip route show default 2>/dev/null \
                | awk '{for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1)}' \
                | head -1)
    fi
    if [ -z "$iface" ]; then
        iface=$(ip -o link show 2>/dev/null | awk -F': ' '$2 != "lo" {print $2}' | head -1)
    fi

    # Router-ID fica vazio de propósito quando ROUTER_ID não é informado: o FRR
    # escolhe sozinho a partir das interfaces existentes. Fixar um valor
    # amarraria o container a uma rede específica, e ele roda em várias.
    rid="$ROUTER_ID"

    # Configuração efêmera: regerada a todo boot, nunca reaproveitada do
    # root-dir persistente do RouterOS.
    case "${ROUTING_PROTOCOL,,}" in
        ospf)
            write_frr_ospf "$iface" "$rid"
            log "frr.conf gerado: OSPF área $OSPF_AREA em $iface, router-id ${rid:-automático}"
            ;;
        bgp)
            if [ -z "$BGP_AS" ] || [ -z "$BGP_PEER" ] || [ -z "$BGP_PEER_AS" ]; then
                warn "ROUTING_PROTOCOL=bgp mas BGP_AS/BGP_PEER/BGP_PEER_AS não foram"
                warn "definidos. O FRR sobe só com o zebra e não anuncia nada."
                : > /etc/frr/frr.conf
            else
                write_frr_bgp "$rid"
                log "frr.conf gerado: BGP AS $BGP_AS, peer $BGP_PEER (AS $BGP_PEER_AS), router-id ${rid:-automático}"
            fi
            ;;
        none)
            log "ROUTING_PROTOCOL=none — o FRR sobe só com o zebra"
            : > /etc/frr/frr.conf
            ;;
        *)
            err "ROUTING_PROTOCOL='$ROUTING_PROTOCOL' inválido (use ospf, bgp ou none)"
            : > /etc/frr/frr.conf
            ;;
    esac

    # Habilita no /etc/frr/daemons apenas o daemon do protocolo em uso: deixar o
    # outro ligado só gera ruído de log e um processo à toa.
    sed -i 's/^zebra=.*/zebra=yes/;s/^ospfd=.*/ospfd=no/;s/^bgpd=.*/bgpd=no/' \
        /etc/frr/daemons 2>/dev/null
    case "${ROUTING_PROTOCOL,,}" in
        ospf)
            sed -i 's/^ospfd=.*/ospfd=yes/' /etc/frr/daemons 2>/dev/null
            grep -q '^ospfd=yes' /etc/frr/daemons 2>/dev/null || echo 'ospfd=yes' >> /etc/frr/daemons
            ;;
        bgp)
            sed -i 's/^bgpd=.*/bgpd=yes/' /etc/frr/daemons 2>/dev/null
            grep -q '^bgpd=yes' /etc/frr/daemons 2>/dev/null || echo 'bgpd=yes' >> /etc/frr/daemons
            ;;
    esac

    chown -R frr:frr /etc/frr /run/frr 2>/dev/null
    chmod 640 /etc/frr/frr.conf 2>/dev/null

    # Com timeout: o FRR não pode segurar o boot. Se o watchfrr travar esperando
    # daemons que não subiram, seguimos para a VPN mesmo assim — um container
    # sem BGP ainda é útil, um container sem VPN não é.
    if timeout 60 /usr/lib/frr/frrinit.sh start; then
        log "FRR iniciado"
    else
        err "FRR não subiu (rc=$?); seguindo sem ele. Rode 'mkvpn-status.sh' para ver o estado."
    fi
}

# ---------------------------------------------------------------------------
# 9. Gateway original — o hook precisa dele para devolver o tráfego da LAN.
# ---------------------------------------------------------------------------
save_original_gateway() {
    local line gw dev
    line=$(ip route show default 2>/dev/null | head -1)
    gw=$(printf '%s' "$line" | awk '{for(i=1;i<NF;i++) if($i=="via") print $(i+1)}')
    dev=$(printf '%s' "$line" | awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}')
    printf '%s' "$gw"  > "$RUNDIR/orig-gw"
    printf '%s' "$dev" > "$RUNDIR/orig-dev"
    if [ -n "$gw" ]; then
        log "gateway original: $gw via $dev (usado para o retorno da LAN)"
    else
        warn "nenhuma rota default encontrada antes de conectar a VPN;"
        warn "o retorno do tráfego da LAN pode não funcionar."
    fi
}

# ---------------------------------------------------------------------------
# 10. VPN
# ---------------------------------------------------------------------------
build_openconnect_args() {
    OC_ARGS=(
        --interface="$VPN_IFACE"
        --script=/usr/local/bin/vpnc-hook.sh
        --user="$VPN_USER"
        --passwd-on-stdin
        --non-inter
        --timestamp
    )
    [ -n "$VPN_GROUP" ]    && OC_ARGS+=(--authgroup="$VPN_GROUP")
    [ -n "$VPN_PROTOCOL" ] && OC_ARGS+=(--protocol="$VPN_PROTOCOL")
    [ -n "$VPN_MTU" ]      && OC_ARGS+=(--mtu="$VPN_MTU")
    is_yes "$VPN_DEBUG"    && OC_ARGS+=(--dump-http-traffic)
    [ -n "$VPN_2FA" ]      && OC_ARGS+=(--form-entry="main:secondary_password=$VPN_2FA")

    if [ -n "$VPN_FORM_ENTRIES" ]; then
        local IFS=';' entry
        for entry in $VPN_FORM_ENTRIES; do
            [ -n "$entry" ] && OC_ARGS+=(--form-entry="$entry")
        done
    fi

    [ -n "$SERVERCERT" ] && OC_ARGS+=(--servercert="$SERVERCERT")

    # Sem aspas de propósito: são argumentos crus escolhidos pelo usuário.
    if [ -n "$VPN_EXTRA_ARGS" ]; then
        # shellcheck disable=SC2206
        OC_ARGS+=($VPN_EXTRA_ARGS)
    fi

    OC_ARGS+=("$VPN_SERVER")
}

run_vpn() {
    local rc

    if is_yes "$DRY_RUN"; then
        log "===================== DRY RUN ====================="
        log "DRY_RUN=yes — o openconnect NÃO será executado e nenhuma tentativa"
        log "de autenticação será gasta. Comando que seria executado (a senha vai"
        log "por stdin, por isso não aparece na linha de comando):"
        log ""
        log "    printf '%s\n' \"\$SENHA\" | openconnect ${OC_ARGS[*]}"
        log ""
        log "O container fica de pé para inspeção (rode mkvpn-status.sh)."
        log "Pare com /container/stop e remova DRY_RUN para conectar de verdade."
        log "==================================================="
        idle_forever
        return 0
    fi

    log "--- conectando em $VPN_SERVER (tentativa única) ---"
    printf '%s\n' "$REAL_PASS" | openconnect "${OC_ARGS[@]}" &
    OC_PID=$!
    wait "$OC_PID"
    rc=$?
    OC_PID=""

    shutting_down && return 0

    if [ "$rc" -eq 0 ]; then
        log "openconnect encerrou normalmente (rc=0)."
    else
        err "openconnect terminou com rc=$rc."
    fi

    # Sem reconexão automática, por decisão de projeto: o concentrador bloqueia
    # a conta após duas falhas de autenticação, e um laço de retry poderia
    # queimar as duas tentativas sozinho. Quem decide tentar de novo é o
    # operador, iniciando o container.
    warn "não haverá reconexão automática. Verifique o motivo acima e inicie o"
    warn "container manualmente quando quiser tentar de novo."
    return "$rc"
}

idle_forever() {
    while ! shutting_down; do
        sleep 5 &
        wait $! 2>/dev/null
    done
}

# ---------------------------------------------------------------------------
# 11. Desligamento limpo — sem isso o RouterOS mata o container com SIGKILL e a
#     sessão fica pendurada no concentrador, atrapalhando a reconexão seguinte.
# ---------------------------------------------------------------------------
OC_PID=""
cleanup() {
    trap '' TERM INT
    touch "$SHUTDOWN_FLAG"
    log "sinal de parada recebido; encerrando..."
    if [ -n "$OC_PID" ] && kill -0 "$OC_PID" 2>/dev/null; then
        log "desconectando a VPN (SIGINT no openconnect)..."
        kill -INT "$OC_PID" 2>/dev/null
        for _ in $(seq 1 10); do
            kill -0 "$OC_PID" 2>/dev/null || break
            sleep 1
        done
        kill -TERM "$OC_PID" 2>/dev/null
    fi
    is_yes "$ENABLE_FRR" && /usr/lib/frr/frrinit.sh stop >/dev/null 2>&1
    pkill -TERM -x squid      2>/dev/null
    pkill -TERM -x microsocks 2>/dev/null
    log "encerrado."
    exit "${1:-0}"
}
trap cleanup TERM INT

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
log "mk-vpn iniciando ($(openconnect --version 2>&1 | head -1))"
dump_env
setup_tun
setup_forwarding
start_socks
start_squid
start_frr
save_original_gateway

if [ -z "$VPN_SERVER" ] || [ -z "$VPN_USER" ]; then
    warn "VPN_SERVER e/ou VPN_USER ausentes — a VPN não será conectada."
    warn "O container fica de pé só com os proxies/FRR, para você depurar."
    idle_forever
    exit 0
fi

if ! resolve_password; then
    err "sem senha utilizável; container fica de pé para depuração."
    idle_forever
    exit 1
fi

SERVERCERT=""
if [ -n "$VPN_FINGERPRINT" ]; then
    SERVERCERT="$VPN_FINGERPRINT"
    log "usando VPN_FINGERPRINT informado: $SERVERCERT"
elif is_yes "$VPN_INSECURE"; then
    warn "VPN_INSECURE=yes — vou confiar no certificado que o servidor apresentar AGORA."
    warn "Isso aceita um man-in-the-middle silenciosamente. Rode uma vez, anote o pin"
    warn "abaixo em VPN_FINGERPRINT e desligue o VPN_INSECURE."
    SERVERCERT=$(probe_fingerprint)
    if [ -n "$SERVERCERT" ]; then
        log ">>> pin detectado: $SERVERCERT"
        log ">>> fixe com: VPN_FINGERPRINT=$SERVERCERT"
    else
        err "não consegui calcular o pin (servidor inalcançável?); seguindo sem --servercert"
    fi
else
    log "validando o certificado pelas CAs do sistema (defina VPN_FINGERPRINT para"
    log "servidores com certificado autoassinado, ou VPN_INSECURE=yes para descobri-lo)"
fi

build_openconnect_args
run_vpn
VPN_RC=$?
cleanup "$VPN_RC"
