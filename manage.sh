#!/bin/bash
export EASYRSA_PKI="/etc/openvpn/easy-rsa/pki"
ACTION=$1
CLIENT=$2
HOST=$(hostname)
CLIENTDIR="/opt/openvpn/clients"

R="\e[0;91m"
G="\e[0;92m"
W="\e[0;97m"
B="\e[1m"
C="\e[0m"

if [ $# -lt 1 ]
then
    echo -e "${W}usage:\n./manage.sh create/revoke <username>\n./manage.sh status\n./manage.sh send <username>\n./manage.sh bulkcreate [amount]${C}"
    exit 1
fi

#######################################
# FUNCTIONS
#######################################

function emailProfile() {
    CLIENT=$1
    PASSWORD=$2

    ### Email the profile to the user
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
    echo "${content}" | mailx -s "Your OpenVPN profile" -a "${CLIENTDIR}/${CLIENT}/${CLIENT}.ovpn" -a "/opt/openvpn/google-auth/${CLIENT}.png" -r "Devops<devops@company.com>" "${CLIENT}@company.com" || { echo -e "${R}${B}error mailing profile to client: ${CLIENT}${C}"; exit 1; }
}

function newClient() {
    # If CLIENT already preset (non‑interactive bulk), skip prompts
    if [[ -z "$CLIENT" ]]; then
        echo ""
        echo "Tell me a name for the client."
        echo "The name must consist of alphanumeric characters. It may also include an underscore or a dash."
        # Validate the client name
        until [[ $CLIENT =~ ^[a-zA-Z0-9_-]+$ ]]; do
            read -rp "Client name: " -e CLIENT
        done
    fi

    # Check if the client already exists
    CLIENTEXISTS=$(tail -n +2 /etc/openvpn/easy-rsa/pki/index.txt | grep -c -E "/CN=$CLIENT$")
    if [[ $CLIENTEXISTS -ne 0 ]]; then
        echo "The specified client CN was already found in easy-rsa, please choose another name."
        exit 1
    fi

    # Prompt for password option if not preset (interactive)
    if [[ -z "$PASS" ]]; then
        echo ""
        echo "Do you want to protect the configuration file with a password?"
        echo "(e.g. encrypt the private key with a password)"
        echo "1) Add a passwordless client"
        echo "2) Use a password for the client"
        until [[ $PASS =~ ^[1-2]$ ]]; do
            read -rp "Select an option [1-2]: " -e -i 1 PASS
        done
    fi

    # Create the system user without a home directory and with nologin shell
    useradd -M -s /usr/sbin/nologin "$CLIENT"
    if [[ $? -ne 0 ]]; then
        echo "Failed to create system user. Exiting."
        exit 1
    fi

    # Generate a random password for the system user
    RANDOM_PASSWORD=$(openssl rand -base64 12)
    echo "$CLIENT:$RANDOM_PASSWORD" | chpasswd

    # Create the client directory if it does not exist
    mkdir -p "$CLIENTDIR/$CLIENT"
    FILE_PATH="$CLIENTDIR/$CLIENT/pass"

    # Generate a random password for the private key if necessary
    if [[ $PASS == "2" ]]; then
        PRIVATE_KEY_PASSWORD=$(openssl rand -base64 12)
        /etc/openvpn/easy-rsa/easyrsa --batch --passout=pass:"$PRIVATE_KEY_PASSWORD" build-client-full "$CLIENT"
        echo "private key pass: $PRIVATE_KEY_PASSWORD" > "$FILE_PATH"
        echo "user password: $RANDOM_PASSWORD" >> "$FILE_PATH"
    else
        /etc/openvpn/easy-rsa/easyrsa --batch build-client-full "$CLIENT" nopass
        echo "user password: $RANDOM_PASSWORD" > "$FILE_PATH"
    fi

    chmod 600 "$FILE_PATH"

    # Generate the custom client.ovpn file in CLIENTDIR
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

    # Google Authenticator setup
    GA_DIR="/opt/openvpn/google-auth"
    mkdir -p "$GA_DIR"
    GA_FILE="$GA_DIR/$CLIENT"
    QR_CODE="$GA_DIR/$CLIENT.png"
    google-authenticator -t -d -f -r 3 -R 30 -W -C -s "$GA_FILE" || { echo "Error generating Google Authenticator profile for $CLIENT"; exit 1; }
    secret=$(head -n 1 "$GA_FILE")
    qrencode -t PNG -o "$QR_CODE" "otpauth://totp/$CLIENT@$HOST?secret=$secret&issuer=openvpn" || { echo "Error generating QR code for $CLIENT"; exit 1; }
    chmod 600 "$GA_FILE" "$QR_CODE"
    echo -e "${G}New client $CLIENT has been created successfully.${C}"
}

#######################################
# ACTION VALIDATION
#######################################

if [[ ! " create revoke status send bulkcreate " =~ " ${ACTION} " ]]; then
    echo -e "${W}usage:\n./manage.sh create/revoke <username>\n./manage.sh status\n./manage.sh send <username>\n./manage.sh bulkcreate [amount]${C}"
    exit 1
fi

#######################################
# BULK CREATE
#######################################

if [ "${ACTION}" == "bulkcreate" ]; then
    TOTAL=${CLIENT:-10}
    if ! [[ "$TOTAL" =~ ^[0-9]+$ ]] || [ "$TOTAL" -lt 1 ] || [ "$TOTAL" -gt 99 ]; then
        echo -e "${R}Amount must be a number between 1 and 99${C}"
        exit 1
    fi
    for i in $(seq 1 "$TOTAL"); do
        USERNAME="openvpn${i}"
        echo -e "${B}---> Creating $USERNAME${C}"
        CLIENT="$USERNAME" PASS=1 newClient || { echo -e "${R}Failed to create $USERNAME${C}"; exit 1; }
    done
    echo -e "${G}${B}Bulk create finished.${C}"
    exit 0
fi

#######################################
# SINGLE CREATE / REVOKE / STATUS / SEND (เดิม)
#######################################

if [ "${ACTION}" == "create" ]; then
    newClient || { echo -e "${R}${B}Error creating new client${C}"; exit 1; }
fi

if [ "${ACTION}" == "revoke" ]; then
    [ -z "${CLIENT}" ] &&  { echo -e "${R}Provide a username to revoke${C}"; exit 1; }
    cd /etc/openvpn/easy-rsa/ || exit 1
    ./easyrsa --batch revoke "${CLIENT}"
    EASYRSA_CRL_DAYS=3650 ./easyrsa gen-crl
    rm -f "pki/reqs/${CLIENT}.req*" "pki/private/${CLIENT}.key*" "pki/issued/${CLIENT}.crt*"
    rm -f /etc/openvpn/crl.pem
    cp /etc/openvpn/easy-rsa/pki/crl.pem /etc/openvpn/crl.pem
    chmod 644 /etc/openvpn/crl.pem
    sed -i "/CN=${CLIENT}$/d" /etc/openvpn/easy-rsa/pki/index.txt
    id "${CLIENT}" && userdel -r -f "${CLIENT}"
    rm -rf "${CLIENTDIR:?}/${CLIENT:?}"
    echo -e "${G}VPN access for $CLIENT is revoked${C}"
fi

if [ "${ACTION}" == "status" ]; then
    grep "^V" /etc/openvpn/easy-rsa/pki/index.txt | grep -v "server_"
fi

if [ "${ACTION}" == "send" ]; then
    [ -z "${CLIENT}" ] && { echo -e "${R}Provide a username to send profile to${C}"; exit 1; }
    PW=$(cat "${CLIENTDIR}/${CLIENT}/pass") || { echo -e "${R}${B}User doesnt exist${C}"; exit 1; }
    emailProfile "${CLIENT}" "${PW}" || { echo -e "${R}${B}Error sending profile to user ${CLIENT}${C}"; exit 1; }
    echo -e "${G}Email profile sent to ${CLIENT} ${C}"
fi
