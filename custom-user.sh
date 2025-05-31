#!/bin/bash

export EASYRSA_PKI="/etc/openvpn/easy-rsa/pki"
ACTION=$1
CLIENTS=("${@:2}")
HOST=$(hostname)
CLIENTDIR="/opt/openvpn/clients"

R="\e[0;91m"
G="\e[0;92m"
W="\e[0;97m"
B="\e[1m"
C="\e[0m"

if [ $# -lt 2 ] && [ "$ACTION" == "create" ]; then
    echo -e "${W}usage:\n./manage.sh create user1 user2 ...\n./manage.sh revoke <username>\n./manage.sh status\n./manage.sh send <username>${C}"
    exit 1
fi

function emailProfile() {
    CLIENT=$1
    PASSWORD=$2

    hostlist=$(grep -vE "#|localhost|127.0.0.1|^$" /etc/hosts)
    content="""
##########    OpenVPN connection profile (${HOST})  ###################

use the attached VPN profile to connect using Tunnelblick or OpenVPN Connect.

VPN usename: ${CLIENT}
VPN password:  ${PASSWORD}

user attached QR code to register your 2 Factor Authentication with Authy.

If DNS is not working, you can use the /etc/hosts list below to connect to hosts:
----------------------------------------
${hostlist}
"""
    echo "${content}" | mailx -s "Your OpenVPN profile" -a "${CLIENTDIR}/${CLIENT}/${CLIENT}.ovpn" -a "/opt/openvpn/google-auth/${CLIENT}.png" -r "Devops<devops@company.com>" "${CLIENT}@company.com" || {
        echo -e "${R}${B}error mailing profile to client: ${CLIENT}${C}"; exit 1;
    }
}

function newClient() {
    CLIENT=$1

    if ! [[ $CLIENT =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "Invalid client name: $CLIENT"
        return 1
    fi

    CLIENTEXISTS=$(tail -n +2 /etc/openvpn/easy-rsa/pki/index.txt | grep -c -E "/CN=$CLIENT$")
    if [[ $CLIENTEXISTS -ne 0 ]]; then
        echo "Client already exists: $CLIENT"
        return 1
    fi

    PASS=1

    useradd -M -s /usr/sbin/nologin "$CLIENT"
    if [[ $? -ne 0 ]]; then
        echo "Failed to create system user $CLIENT."
        return 1
    fi

    RANDOM_PASSWORD=$(openssl rand -base64 12)
    echo "$CLIENT:$RANDOM_PASSWORD" | chpasswd

    mkdir -p "$CLIENTDIR/$CLIENT"
    FILE_PATH="$CLIENTDIR/$CLIENT/pass"

    /etc/openvpn/easy-rsa/easyrsa --batch build-client-full "$CLIENT" nopass
    echo "user password: $RANDOM_PASSWORD" > "$FILE_PATH"

    chmod 600 "$FILE_PATH"

    cp /etc/openvpn/client-template.txt "$CLIENTDIR/$CLIENT/${CLIENT}.ovpn"
    {
        echo 'static-challenge "Enter OTP: " 1'
        echo 'auth-user-pass'
        echo "<ca>"
        cat "/etc/openvpn/easy-rsa/pki/ca.crt"
        echo "</ca>"
        echo "<cert>"
        awk '/BEGIN/,/END CERTIFICATE/' "/etc/openvpn/easy-rsa/pki/issued/$CLIENT.crt"
        echo "</cert>"
        echo "<key>"
        cat "/etc/openvpn/easy-rsa/pki/private/$CLIENT.key"
        echo "</key>"
        if grep -qs "^tls-crypt" /etc/openvpn/server.conf; then
            echo "<tls-crypt>"
            cat /etc/openvpn/tls-crypt.key
            echo "</tls-crypt>"
        elif grep -qs "^tls-auth" /etc/openvpn/server.conf; then
            echo "key-direction 1"
            echo "<tls-auth>"
            cat "/etc/openvpn/tls-auth.key"
            echo "</tls-auth>"
        fi
    } >> "$CLIENTDIR/$CLIENT/${CLIENT}.ovpn"

    GA_DIR="/opt/openvpn/google-auth"
    mkdir -p "$GA_DIR"
    GA_FILE="$GA_DIR/$CLIENT"
    QR_CODE="$GA_DIR/$CLIENT.png"

    google-authenticator -t -d -f -r 3 -R 30 -W -C -s "$GA_FILE" || {
        echo "Error generating Google Authenticator for $CLIENT"; return 1;
    }

    secret=$(head -n 1 "$GA_FILE")
    qrencode -t PNG -o "$QR_CODE" "otpauth://totp/$CLIENT@$HOST?secret=$secret&issuer=openvpn" || {
        echo "Error generating QR code for $CLIENT"; return 1;
    }

    chmod 600 "$GA_FILE" "$QR_CODE"

    return 0
}

if [[ "$ACTION" == "create" ]]; then
    for client in "${CLIENTS[@]}"; do
        echo -e "\nCreating user: ${client}"
        newClient "$client"
        if [[ $? -eq 0 ]]; then
            echo -e "${G}Client $client created successfully.${C}"
        else
            echo -e "${R}Failed to create $client.${C}"
        fi
    done
fi

# The rest of the script (revoke, status, send) remains unchanged
