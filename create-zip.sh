#!/bin/bash
# create-zip.sh – package each OpenVPN client as  <user>.zip
#   • <user>.ovpn
#   • pass
#   • <user>.png   (QR)

set -euo pipefail

OPENVPN_DIR="/opt/openvpn/clients"
GA_DIR="/opt/openvpn/google-auth"

install_zip_utility() {
  command -v zip &>/dev/null && return        # มี zip แล้ว
  echo "zip not found, installing …"
  if   command -v apt-get &>/dev/null; then sudo apt-get update -y && sudo apt-get install -y zip
  elif command -v yum     &>/dev/null; then sudo yum install -y zip
  elif command -v dnf     &>/dev/null; then sudo dnf install -y zip
  else echo "please install zip manually" >&2; exit 1
  fi
}

create_zip_file() {
  local user=$1
  local client_dir="${OPENVPN_DIR}/${user}"
  local qr_png="${GA_DIR}/${user}.png"
  local zip_file="${OPENVPN_DIR}/${user}.zip"

  # ไฟล์ที่ต้องการ
  local ovpn="${client_dir}/${user}.ovpn"
  local pass="${client_dir}/pass"

  # ตรวจครบหรือยัง
  for f in "$ovpn" "$pass" "$qr_png"; do
    [[ -f $f ]] || { echo "[warn] missing $f – skip $user"; return; }
  done

  echo "[+] packaging ${user}.zip"
  # -j = ไม่ใส่ path  -q = เงียบ ๆ
  zip -jq "$zip_file" "$ovpn" "$pass" "$qr_png"
}

[[ $(id -u) -eq 0 ]] || { echo "run as root" >&2; exit 1; }
install_zip_utility

shopt -s nullglob
for dir in "$OPENVPN_DIR"/*/ ; do          # วนทุกโฟลเดอร์ลูก
  user=$(basename "$dir")
  create_zip_file "$user"
done
shopt -u nullglob

echo "Done."
