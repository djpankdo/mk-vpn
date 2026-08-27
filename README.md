# mk-vpn

Container que roda uma VPN **OpenConnect** (Cisco AnyConnect e compatíveis) dentro do
RouterOS de um MikroTik, expõe proxies **SOCKS5** e **HTTP** para a LAN, e usa **FRR/BGP**
para devolver ao roteador as rotas aprendidas ao conectar o túnel.

Alvo: RouterOS v7, arquitetura **arm64**, com o container em storage externo
(NVMe/USB/NAND).

---

## Arquitetura

```
LAN 192.168.88.0/24
        │
   ┌────┴─────────────────────────────┐
   │ MikroTik (RouterOS v7)           │
   │                                  │
   │  bridge containers 172.19.0.1/24 │
   │        │                         │
   │        │  BGP (AS 65001 ⇄ 65002) │  ← o container anuncia as redes da VPN
   │        │                         │
   │   ┌────┴──────────────────────┐  │
   │   │ container mk-vpn          │  │
   │   │  veth 172.19.0.2/24       │  │
   │   │  ├ openconnect → tun0 ────┼──┼──→ concentrador VPN
   │   │  ├ FRR (bgpd + zebra)     │  │
   │   │  ├ microsocks :1080       │  │
   │   │  └ squid      :3128       │  │
   │   └───────────────────────────┘  │
   └──────────────────────────────────┘
```

O roteador decide o que vai para a VPN a partir das rotas que o FRR anuncia; o container
faz NAT na saída do `tun0`. Por isso `VPN_DEFAULT_ROUTE` vem como `no` por padrão — o
túnel **não** rouba a rota default do container.

---

## Variáveis de ambiente

### VPN

| Variável | Default | Descrição |
|---|---|---|
| `VPN_SERVER` | — | Host, `host:porta` ou URL do concentrador. **Obrigatória.** |
| `VPN_USER` | — | Usuário. **Obrigatória.** |
| `VPN_PASS` | — | Senha em texto puro. |
| `VPN_PASS_B64` | — | Senha em base64. Use esta se a senha tem caracteres que o parser do RouterOS engasga (`$`, `;`, `=`, espaços). |
| `VPN_PASS_FILE` | — | Caminho de um arquivo (via mount) com a senha na primeira linha. É a opção mais segura. |
| `VPN_GROUP` | — | `--authgroup`. |
| `VPN_PROTOCOL` | auto | `anyconnect`, `gp`, `nc`, `pulse`, `f5`, `fortinet`, `array`. |
| `VPN_2FA` | — | Atalho para `--form-entry main:secondary_password=<valor>` (ex.: `push`, ou o token). |
| `VPN_FORM_ENTRIES` | — | Vários form-entries separados por `;`, ex.: `main:secondary_password=push;main:group_list=TI`. |
| `VPN_FINGERPRINT` | — | `pin-sha256:...` do certificado do servidor. |
| `VPN_INSECURE` | `no` | `yes` = descobre o pin sozinho e confia nele. Aceita MITM — use só para descobrir o valor, depois fixe em `VPN_FINGERPRINT`. |
| `VPN_IFACE` | `tun0` | Nome da interface do túnel. |
| `VPN_MTU` | auto | `--mtu`. |
| `VPN_EXTRA_ARGS` | — | Argumentos crus repassados ao `openconnect`. |
| `VPN_DEFAULT_ROUTE` | `no` | `yes` = o túnel fica com a rota default do container (full tunnel). Exige `LAN_ROUTES`. |
| `VPN_RETRY_DELAY` | `15` | Segundos entre tentativas de reconexão. |

### Roteamento

| Variável | Default | Descrição |
|---|---|---|
| `LAN_ROUTES` | — | Prefixos que devem voltar pelo gateway do MikroTik, separados por espaço (ex.: `192.168.88.0/24 10.20.0.0/16`). Obrigatório quando `VPN_DEFAULT_ROUTE=yes`. |
| `ENABLE_NAT` | `yes` | `MASQUERADE` na saída do túnel. |
| `ENABLE_MSS_CLAMP` | `yes` | Clamp de MSS ao PMTU. Desligar isso é o caminho mais rápido para "ping funciona, HTTPS trava". |

### Proxies

| Variável | Default | Descrição |
|---|---|---|
| `ENABLE_SOCKS` | `yes` | |
| `SOCKS_PORT` | `1080` | |
| `SOCKS_BIND` | `0.0.0.0` | |
| `SOCKS_USER` / `SOCKS_PASS` | — | Autenticação do microsocks. Sem elas o proxy é aberto. |
| `ENABLE_SQUID` | `yes` | |
| `SQUID_PORT` | `3128` | |
| `PROXY_ALLOW` | `10.0.0.0/8 172.16.0.0/12 192.168.0.0/16` | Redes autorizadas no Squid. |

### BGP / FRR

| Variável | Default | Descrição |
|---|---|---|
| `ENABLE_FRR` | `yes` | |
| `BGP_AS` | — | ASN do container (ex.: `65002`). |
| `BGP_PEER` | — | IP do MikroTik na rede do container (ex.: `172.19.0.1`). |
| `BGP_PEER_AS` | — | ASN do MikroTik (ex.: `65001`). |
| `BGP_ROUTER_ID` | IP do veth | |
| `BGP_ADVERTISE_DEFAULT` | `no` | `yes` anuncia `0.0.0.0/0` ao MikroTik — cuidado, isso sequestra a saída inteira do roteador. |

Se você montar seu próprio `/etc/frr/frr.conf` ou `/etc/squid/squid.conf`, o container
detecta e não sobrescreve.

---

## Configuração no RouterOS

Ajuste `disk1` para o nome do seu storage e `172.19.0.0/24` para a rede que preferir.

### 1. Rede do container

```routeros
/interface/veth/add name=veth-vpn address=172.19.0.2/24 gateway=172.19.0.1
/interface/bridge/add name=containers
/interface/bridge/port/add bridge=containers interface=veth-vpn
/ip/address/add address=172.19.0.1/24 interface=containers

# saída para a internet do próprio container (para ele alcançar o concentrador)
/ip/firewall/nat/add chain=srcnat action=masquerade src-address=172.19.0.0/24

# a LAN precisa alcançar os proxies do container
/ip/firewall/filter/add chain=forward action=accept \
    src-address=192.168.88.0/24 dst-address=172.19.0.2 comment="LAN -> mk-vpn"
```

### 2. Ambiente

```routeros
/container/config/set registry-url=https://registry-1.docker.io \
    tmpdir=disk1/pull layer-dir=disk1/layers

/container/envs/add name=vpn key=VPN_SERVER   value="vpn.suaempresa.com"
/container/envs/add name=vpn key=VPN_USER     value="seu.usuario"
/container/envs/add name=vpn key=VPN_PASS_B64 value="c3VhLXNlbmhh"
/container/envs/add name=vpn key=VPN_GROUP    value="SEU-GRUPO"
/container/envs/add name=vpn key=LAN_ROUTES   value="192.168.88.0/24"
/container/envs/add name=vpn key=PROXY_ALLOW  value="192.168.88.0/24"
/container/envs/add name=vpn key=BGP_AS       value="65002"
/container/envs/add name=vpn key=BGP_PEER     value="172.19.0.1"
/container/envs/add name=vpn key=BGP_PEER_AS  value="65001"
```

> **Senha:** gere o base64 **sem** quebra de linha —
> `printf '%s' 'minha-senha' | base64`. Um `echo` comum acrescenta `\n` e a
> autenticação falha com uma mensagem genérica.

### 3. Mounts (opcionais, mas recomendados)

```routeros
/container/mounts/add name=mkvpn-frr   src=disk1/mk-vpn/frr   dst=/etc/frr
/container/mounts/add name=mkvpn-squid src=disk1/mk-vpn/squid dst=/etc/squid
```

### 4. O container

```routeros
/container/add remote-image=SEUUSUARIO/mk-vpn:latest \
    interface=veth-vpn \
    envlist=vpn \
    mounts=mkvpn-frr,mkvpn-squid \
    root-dir=disk1/mk-vpn/root \
    logging=yes \
    start-on-boot=yes

/container/start 0
/log/print where topics~"container"
```

### 5. BGP no MikroTik

```routeros
/routing/bgp/connection/add name=mk-vpn \
    remote.address=172.19.0.2 remote.as=65002 \
    local.role=ebgp as=65001 router-id=172.19.0.1 \
    address-families=ip routing-table=main

/routing/bgp/session/print
/ip/route/print where bgp
```

---

## Depuração

Ao iniciar, o container imprime **todas** as variáveis que reconheceu (segredos aparecem
só como contagem de caracteres) e lista as que **não** reconheceu — é assim que se pega
erro de digitação no `envlist`, que o RouterOS aceita calado.

```routeros
/container/shell 0
```

```sh
mkvpn-status.sh     # processos, rotas, iptables, BGP, portas em escuta
```

Checagens rápidas:

```sh
ip a show tun0                       # o túnel subiu?
ip route show                        # as rotas do split tunnel entraram?
vtysh -c 'show bgp summary'          # a sessão com o MikroTik está Established?
vtysh -c 'show bgp ipv4 unicast'     # o que estamos anunciando?
iptables -t nat -S POSTROUTING       # o MASQUERADE está lá?
```

---

## Build

O GitHub Actions (`.github/workflows/build.yml`) builda `linux/arm64` e `linux/amd64` e
publica no Docker Hub a cada push na `main`. Configure os segredos
`DOCKERHUB_USERNAME` e `DOCKERHUB_TOKEN` no repositório.

Build manual:

```sh
docker buildx build --platform linux/arm64 -t SEUUSUARIO/mk-vpn:latest --push .
```

---

## Segurança

- microsocks e Squid escutam em `0.0.0.0` dentro do container. Restrinja o acesso pelo
  firewall do MikroTik e/ou use `SOCKS_USER`/`SOCKS_PASS` e `PROXY_ALLOW`. Um proxy aberto
  aqui é uma porta de entrada para a rede corporativa.
- Prefira `VPN_PASS_FILE` a `VPN_PASS`/`VPN_PASS_B64`: variáveis de ambiente aparecem em
  `/container/envs/print` e no ambiente de qualquer processo do container. Base64 não é
  criptografia.
- Deixe `VPN_INSECURE=no` em produção. Use-o uma vez para descobrir o pin, fixe o valor em
  `VPN_FINGERPRINT` e desligue.
