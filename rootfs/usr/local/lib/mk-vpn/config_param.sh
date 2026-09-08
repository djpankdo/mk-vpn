# Decodificador do CONFIG_PARAM - compartilhado pelo entrypoint e pelo
# healthcheck. Nao e executavel: e para ser lido com ". <arquivo>".
#
# CONFIG_PARAM e uma mascara hexadecimal de 4 digitos que desliga modulos, um
# por bit. Existe porque a envlist do RouterOS e desconfortavel de manter --
# cada chave e um "/container/envs/add" separado -- entao uma variavel unica no
# lugar de varias ENABLE_* e ganho pratico ali.
#
# Duas regras que nao mudam:
#
#  1. Bit em 1 DESLIGA. Bit em 0 nao liga nada: deixa a variavel ENABLE_*
#     correspondente decidir, como sempre. A mascara e um veto, nunca um
#     interruptor de ligar. Assim CONFIG_PARAM ausente, ou "0000", e exatamente
#     o comportamento de antes de ela existir.
#
#  2. A posicao de cada nome em CP_NOMES E o numero do bit, e o significado de
#     um bit ja publicado nao muda nunca: quem gravou CONFIG_PARAM na envlist do
#     roteador espera a mesma coisa depois de atualizar a imagem. Para
#     acrescentar modulo, some no fim da lista; para aposentar um, deixe o nome
#     no lugar em vez de remover, para nao deslocar os demais.
#
# Este arquivo serve aos dois scripts de proposito. O healthcheck decide o que
# cobrar a partir das mesmas variaveis, entao um modulo desligado so no
# entrypoint continuaria sendo cobrado la: o container ficaria "unhealthy" e,
# com stop-on-unhealthy, o RouterOS o pararia. Desligar um modulo derrubaria
# tudo.
#
# Bit 0 e o menos significativo. Os que nao tem nome estao reservados.
#
#   0  0001  socks          microsocks
#   1  0002  squid          Squid
#   2  0004  frr            FRR/OSPF
#   3  0008  anycast        IP anycast na loopback
#   4  0010  vpn            openconnect
#   5  0020  cert_probe     sonda do certificado do concentrador no boot
#   6  0040  kernel_routes  redistribuicao das rotas kernel no OSPF
#   7  0080  hc_ping        teste de ping do healthcheck
#
# A interface TUN, o NAT na saida do tunel e o clamp de MSS nao tem bit por
# decisao de projeto: os tres sao sempre necessarios.
CP_NOMES="socks squid frr anycast vpn cert_probe kernel_routes hc_ping"

CP_MASK=0
CP_DESLIGADOS=""
CP_AVISO=""

cp_decode() {
    local v="${CONFIG_PARAM:-}"
    local i=0 nome
    CP_MASK=0
    CP_DESLIGADOS=""
    CP_AVISO=""

    [ -n "$v" ] || return 0

    case "$v" in
        [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) ;;
        *)
            # Valor malformado nao pode derrubar nada: avisa e segue como se a
            # variavel nao existisse. Punir um erro de digitacao desligando
            # modulos ao acaso, ou recusando o boot, seria pior que ignorar.
            CP_AVISO="CONFIG_PARAM='$v' nao e um hexadecimal de 4 digitos; ignorando"
            return 0
            ;;
    esac

    CP_MASK=$((16#$v))
    for nome in $CP_NOMES; do
        if [ $(( (CP_MASK >> i) & 1 )) -eq 1 ]; then
            CP_DESLIGADOS="$CP_DESLIGADOS $nome"
        fi
        i=$((i + 1))
    done

    # Bits reservados nao fazem nada. Avisar evita que um valor digitado errado
    # passe por intencional.
    if [ $(( CP_MASK >> i )) -ne 0 ]; then
        CP_AVISO="CONFIG_PARAM=$v usa bits reservados (acima do bit $((i - 1))), que nao tem efeito"
    fi
    return 0
}

# Verdadeiro quando o modulo esta desligado pela mascara.
cp_off() {
    case " $CP_DESLIGADOS " in
        *" $1 "*) return 0 ;;
        *)        return 1 ;;
    esac
}

# Texto para o log: o valor cru nao diz nada a quem le o log de madrugada.
cp_resumo() {
    # Testa a lista, e nao a mascara: um valor que so acende bits reservados tem
    # mascara diferente de zero e mesmo assim nao desativa nada.
    if [ -z "$CP_DESLIGADOS" ]; then
        printf 'nenhum modulo desativado'
    else
        printf 'desativados:%s' "$CP_DESLIGADOS"
    fi
}
