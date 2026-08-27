# mk-vpn

Container que roda uma VPN **OpenConnect** (Cisco AnyConnect e compatíveis) dentro do
RouterOS de um MikroTik, expõe proxies **SOCKS5** e **HTTP** para a LAN, e usa **FRR/OSPF**
para devolver ao roteador as rotas aprendidas ao conectar o túnel.

Alvo: RouterOS v7, arquitetura **arm64**, com o container em storage externo
(NVMe/USB/NAND).

> ## ⚠️ Sem reconexão automática — e por quê
>
> O concentrador **bloqueia a conta após duas falhas de autenticação**. Por isso o
> container **nunca** tenta reconectar sozinho: quando o openconnect termina, por qualquer
> motivo, tudo é encerrado e o container sai. Quem decide tentar de novo é você, iniciando
> o container.
>
> Antes de mexer em qualquer coisa que afete a linha de comando do openconnect, use
> `DRY_RUN=yes`: o container faz o boot inteiro — TUN, encaminhamento, proxies, FRR,
> decodificação da senha — e apenas **registra no log o comando que seria executado**, sem
> gastar tentativa de autenticação.

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
   │        │  OSPF area 0.0.0.0       │  ← o container anuncia as redes da VPN
   │        │                         │
   │   ┌────┴──────────────────────┐  │
   │   │ container mk-vpn          │  │
   │   │  veth 172.19.0.2/24       │  │
   │   │  ├ openconnect → tun0 ────┼──┼──→ concentrador VPN
   │   │  ├ FRR (ospfd + zebra)    │  │
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
| `VPN_DEBUG` | `no` | `yes` acrescenta `--dump-http-traffic`. **Cuidado:** isso despeja o tráfego HTTP da autenticação no log do RouterOS, credenciais inclusive. |
| `DRY_RUN` | `no` | `yes` faz todo o boot mas **não** executa o openconnect: apenas registra no log o comando que seria executado, e mantém o container de pé para inspeção. |

### Roteamento

| Variável | Default | Descrição |
|---|---|---|
| `LAN_ROUTES` | — | Só é necessário com `VPN_DEFAULT_ROUTE=yes`. No modo padrão a rota default do container continua apontando para o MikroTik, e o retorno da LAN funciona por ela — sem precisar listar prefixo nenhum. |
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
| `PROXY_ALLOW` | `10.0.0.0/8 172.16.0.0/12 192.168.0.0/16` | Redes autorizadas no Squid. As sub-redes conectadas do próprio container são acrescentadas automaticamente, então normalmente não há o que ajustar ao mudar de rede. |

### Roteamento dinâmico (FRR)

| Variável | Default | Descrição |
|---|---|---|
| `ENABLE_FRR` | `yes` | |
| `ROUTING_PROTOCOL` | `ospf` | `ospf`, `bgp` ou `none`. |
| `ROUTER_ID` | automático | Deixe vazio: o FRR escolhe sozinho a partir das interfaces existentes. Fixar um valor amarraria o container a uma rede específica. |
| `UPLINK_IFACE` | auto | Interface voltada ao MikroTik. Por padrão é detectada como a que carrega a rota default antes de a VPN subir. |
| `ADVERTISE_DEFAULT` | `no` | `yes` anuncia `0.0.0.0/0` ao MikroTik — cuidado, isso sequestra a saída inteira do roteador. |
| `OSPF_AREA` | `0.0.0.0` | |
| `OSPF_COST` | — | Custo da interface. |
| `OSPF_HELLO` / `OSPF_DEAD` | — | Temporizadores. Precisam bater com os do MikroTik, senão a adjacência não fecha. |
| `OSPF_MD5_KEY` | — | Se definido, ativa autenticação `message-digest`. |
| `OSPF_MD5_KEY_ID` | `1` | ID da chave MD5. |
| `BGP_AS` / `BGP_PEER` / `BGP_PEER_AS` | — | Só com `ROUTING_PROTOCOL=bgp`. |

O container roda o OSPF **apenas** na interface voltada ao MikroTik (`passive-interface
default` mais `no passive-interface <veth>`), então ele nunca tenta formar adjacência pelo
túnel. As rotas do split tunnel entram no zebra como `kernel`, porque quem as instala é o
`vpnc-script`; daí o `redistribute kernel`.

## Configurações são efêmeras

O `frr.conf` e o `squid.conf` são **regerados a cada boot** a partir das variáveis de
ambiente e do estado observado da rede. Isso é proposital: a mesma imagem roda em redes
diferentes, e nada pode ficar preso ao endereçamento da rede anterior — ainda mais porque
o `root-dir` do container persiste no storage entre reinícios. Editar esses arquivos por
dentro do container não adianta, eles são sobrescritos.

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
/container/envs/add name=vpn key=VPN_FINGERPRINT  value="pin-sha256:..."
/container/envs/add name=vpn key=ROUTING_PROTOCOL value="ospf"

# na primeira vez, valide sem gastar tentativa de autenticação:
/container/envs/add name=vpn key=DRY_RUN value="yes"
```

> **Senha:** gere o base64 **sem** quebra de linha —
> `printf '%s' 'minha-senha' | base64`. Um `echo` comum acrescenta `\n` e a
> autenticação falha com uma mensagem genérica.

### 3. Mounts

Nenhum é necessário. As configurações do FRR e do Squid são geradas no boot, e um mount
sobre `/etc/frr` ou `/etc/squid` seria sobrescrito.

### 4. O container

```routeros
/container/add remote-image=SEUUSUARIO/mk-vpn:latest \
    interface=veth-vpn \
    envlist=vpn \
    root-dir=disk1/mk-vpn/root \
    logging=yes \
    start-on-boot=yes

/container/start 0
/log/print where topics~"container"
```

### 5. OSPF no MikroTik

```routeros
/routing/ospf/instance/add name=ospf-mkvpn version=2 router-id=172.19.0.1
/routing/ospf/area/add name=backbone instance=ospf-mkvpn area-id=0.0.0.0
/routing/ospf/interface-template/add \
    interfaces=bridge_containers area=backbone type=broadcast

/routing/ospf/neighbor/print
/ip/route/print where ospf
```

Com autenticação (precisa casar com `OSPF_MD5_KEY`/`OSPF_MD5_KEY_ID` no container):

```routeros
/routing/ospf/interface-template/set 0 auth=md5 auth-id=1 auth-key="sua-chave"
```

> O template de interface deve cobrir **apenas** a bridge dos containers. Se ele pegar a
> interface da LAN ou da WAN, o roteador passa a mandar hello de OSPF para onde não deve.

---

## Depuração

Ao iniciar, o container imprime **todas** as variáveis que reconheceu (segredos aparecem
só como contagem de caracteres) e lista as que **não** reconheceu — é assim que se pega
erro de digitação no `envlist`, que o RouterOS aceita calado.

```routeros
/container/shell 0
```

```sh
mkvpn-status.sh     # processos, rotas, iptables, OSPF, portas em escuta
```

Checagens rápidas:

```sh
ip a show tun0                       # o túnel subiu?
ip route show                        # as rotas do split tunnel entraram?
vtysh -c 'show ip ospf neighbor'     # a adjacência com o MikroTik está Full?
vtysh -c 'show ip route'             # o que o zebra vê e vai redistribuir?
iptables -t nat -S POSTROUTING       # o MASQUERADE está lá?
```

---

## Build

O GitHub Actions (`.github/workflows/build.yml`) builda `linux/arm64` e `linux/amd64` e
publica no Docker Hub a cada push na `main`. Configure os segredos
`DOCKERHUB_USERNAME` e `DOCKERHUB_TOKEN` no repositório.

Enquanto esses segredos não existirem, o workflow ainda roda e builda as duas
arquiteturas — serve como teste de compilação — apenas sem publicar. Em pull request ele
nunca publica.

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
