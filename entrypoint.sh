#!/bin/bash

# 1. Garante a existência do nó TUN para a VPN
mkdir -p /dev/net
if [ ! -c /dev/net/tun ]; then
    mknod /dev/net/tun c 10 200
    chmod 666 /dev/net/tun
fi

# 2. Ativa o encaminhamento de pacotes no kernel
sysctl -w net.ipv4.ip_forward=1

# 3. Inicia o Microsocks (Porta 1080)
microsocks -p 1080 &

# 4. Inicia o Squid
service squid start

# 5. Inicia o FRR
chown -R frr:frr /etc/frr
if [ -f /usr/lib/frr/frrinit.sh ]; then
    /usr/lib/frr/frrinit.sh start
else
    /usr/lib/frr/frr start
fi

# 6. Conexão Automática com a VPN OpenConnect
if [ -n "$VPN_SERVER" ] && [ -n "$VPN_USER" ]; then
    echo "--- Iniciando processo de conexão VPN para $VPN_SERVER ---"

    # Trata a senha (aceita texto simples ou Base64 via VPN_PASS_B64)
    REAL_PASS=""
    if [ -n "$VPN_PASS_B64" ]; then
        REAL_PASS=$(echo "$VPN_PASS_B64" | base64 -d 2>/dev/null)
    elif [ -n "$VPN_PASS" ]; then
        REAL_PASS="$VPN_PASS"
    fi

    # Monta opções adicionais (Group / MFA Push / Form Entries)
    EXTRA_ARGS=""
    if [ -n "$VPN_GROUP" ]; then
        EXTRA_ARGS="$EXTRA_ARGS --authgroup=$VPN_GROUP"
    fi
    if [ -n "$VPN_2FA" ]; then
        EXTRA_ARGS="$EXTRA_ARGS --form-entry main:secondary_password=$VPN_2FA"
    fi

    # --- AUTO-DESCOBERTA DO CERTIFICADO (FINGERPRINT) ---
    SERVERCERT_ARG=""
    if [ -n "$VPN_FINGERPRINT" ]; then
        echo ">>> Usando VPN_FINGERPRINT informado manualmente: $VPN_FINGERPRINT"
        SERVERCERT_ARG="--servercert $VPN_FINGERPRINT"
    else
        echo ">>> Sondando o servidor para detectar o certificado..."
        PROBE_OUT=$(echo "" | openconnect "$VPN_SERVER" --non-inter 2>&1)
        DETECTED_CERT=$(echo "$PROBE_OUT" | grep -oE '(pin-sha256|sha256|sha1):[^ ]+' | head -n1)

        if [ -n "$DETECTED_CERT" ]; then
            echo ">>> Certificado autoassinado detectado automaticamente: $DETECTED_CERT"
            SERVERCERT_ARG="--servercert $DETECTED_CERT"
        else
            echo ">>> Nenhum certificado autoassinado pendente (Servidor usa CA válida ou padrão)."
        fi
    fi

    # Efetua a conexão real com a VPN
    if [ -n "$REAL_PASS" ]; then
        echo "$REAL_PASS" | openconnect --background \
            --interface=tun0 \
            -u "$VPN_USER" \
            $EXTRA_ARGS \
            $SERVERCERT_ARG \
            --passwd-on-stdin \
            --non-inter \
            "$VPN_SERVER"
        
        echo "--- Comando da VPN enviado. Verificando interface tun0 em 5s... ---"
        sleep 5
        if ip a show tun0 >/dev/null 2>&1; then
            echo "--- SUCESSO: Interface tun0 criada e conectada! ---"
        else
            echo "--- ATENÇÃO: Interface tun0 não foi detectada. Verifique as credenciais. ---"
        fi
    else
        echo "ERRO: Nenhuma senha foi informada (use VPN_PASS ou VPN_PASS_B64)."
    fi
else
    echo "--- VPN OpenConnect não configurada (VPN_SERVER e VPN_USER ausentes) ---"
fi

echo "--- Container de Rede Pronto (pankdo/mk-vpn) ---"

# 7. Processo mantido em primeiro plano para o MikroTik
tail -f /dev/null
