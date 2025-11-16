#!/usr/bin/env bash
set -euo pipefail

if [[ ${BASH_VERSINFO[0]} -lt 4 ]]; then
  echo "This installer requires bash 4 or newer." >&2
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "Please run this script with sudo: sudo ./install.sh" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTOHUB_ROOT="$SCRIPT_DIR"
CONFIG_DIR="$AUTOHUB_ROOT/config"
ENV_FILE="$CONFIG_DIR/autohub.env"
ALLOW_FILE="$CONFIG_DIR/clients.allow"
SYSTEM_CONF="/etc/autohub-usbip.conf"

TARGET_USER=${SUDO_USER:-root}
TARGET_GROUP=$(id -gn "$TARGET_USER")
TOTAL_STEPS=7
CURRENT_STEP=0

default_win_host="192.168.1.2"
default_win_port="59876"
default_win_path="/usb-event/"
default_curl_timeout="1"

step() {
  CURRENT_STEP=$((CURRENT_STEP + 1))
  printf '\n[%d/%d] %s\n' "$CURRENT_STEP" "$TOTAL_STEPS" "$1"
}

prompt_with_default() {
  local prompt=$1
  local default=$2
  local reply
  read -r -p "$prompt [$default]: " reply
  if [[ -z $reply ]]; then
    echo "$default"
  else
    echo "$reply"
  fi
}

prompt_yes_no() {
  local prompt=$1
  local default=${2:-Y}
  local default_display
  case "$default" in
    Y|y) default_display="Y/n" ;;
    N|n) default_display="y/N" ;;
    *) default_display="y/n" ;;
  esac
  while true; do
    read -r -p "$prompt ($default_display): " reply
    if [[ -z $reply ]]; then
      reply=$default
    fi
    case "$reply" in
      Y|y) return 0 ;;
      N|n) return 1 ;;
    esac
    echo "Please answer y or n." >&2
  done
}

value_from_file() {
  local file=$1
  local key=$2
  if [[ -f $file ]]; then
    grep -E "^${key}=" "$file" | tail -n1 | cut -d= -f2-
  fi
}

write_repo_file() {
  local dest=$1
  local tmp
  tmp=$(mktemp)
  cat >"$tmp"
  install -o "$TARGET_USER" -g "$TARGET_GROUP" -m 0644 "$tmp" "$dest"
  rm -f "$tmp"
}

write_root_file() {
  local dest=$1
  local tmp
  tmp=$(mktemp)
  cat >"$tmp"
  install -o root -g root -m 0644 "$tmp" "$dest"
  rm -f "$tmp"
}

ensure_packages() {
  step "Install required packages"
  if prompt_yes_no "Install/upgrade usbip, nftables, and curl via apt-get?" Y; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y usbip nftables curl
  else
    echo "Skipping package installation."
  fi
}

configure_usbipd() {
  step "Configure usbipd for IPv4-only mode"
  mkdir -p /etc/systemd/system/usbipd.service.d
  cat <<'EOF' >/etc/systemd/system/usbipd.service.d/override.conf
[Service]
ExecStart=
ExecStart=/usr/sbin/usbipd -4
EOF
  systemctl daemon-reload
  systemctl enable --now usbipd.service 2>/dev/null || true
  systemctl restart usbipd.service
}

collect_listener_settings() {
  local env_host env_port env_path env_timeout conf_host conf_port conf_path conf_timeout
  env_host=$(value_from_file "$ENV_FILE" WIN_HOST || true)
  env_port=$(value_from_file "$ENV_FILE" WIN_PORT || true)
  env_path=$(value_from_file "$ENV_FILE" WIN_PATH || true)
  env_timeout=$(value_from_file "$ENV_FILE" CURL_TIMEOUT || true)

  conf_host=$(value_from_file "$SYSTEM_CONF" WIN_HOST || true)
  conf_port=$(value_from_file "$SYSTEM_CONF" WIN_PORT || true)
  conf_path=$(value_from_file "$SYSTEM_CONF" WIN_PATH || true)
  conf_timeout=$(value_from_file "$SYSTEM_CONF" CURL_TIMEOUT || true)

  WIN_HOST=${env_host:-${conf_host:-$default_win_host}}
  WIN_PORT=${env_port:-${conf_port:-$default_win_port}}
  WIN_PATH=${env_path:-${conf_path:-$default_win_path}}
  CURL_TIMEOUT=${env_timeout:-${conf_timeout:-$default_curl_timeout}}

  WIN_HOST=$(prompt_with_default "Windows listener host/IP" "$WIN_HOST")

  while true; do
    local candidate
    candidate=$(prompt_with_default "Windows listener port" "$WIN_PORT")
    if [[ $candidate =~ ^[0-9]+$ ]] && ((candidate >= 1 && candidate <= 65535)); then
      WIN_PORT=$candidate
      break
    fi
    echo "Port must be an integer between 1 and 65535." >&2
  done

  while true; do
    local candidate
    candidate=$(prompt_with_default "Windows listener path" "$WIN_PATH")
    if [[ -z $candidate ]]; then
      echo "Path cannot be empty." >&2
    else
      [[ $candidate == /* ]] || candidate="/$candidate"
      WIN_PATH=$candidate
      break
    fi
  done

  while true; do
    local candidate
    candidate=$(prompt_with_default "curl timeout (seconds)" "$CURL_TIMEOUT")
    if [[ $candidate =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      CURL_TIMEOUT=$candidate
      break
    fi
    echo "Timeout must be numeric." >&2
  done
}

configure_env_file() {
  step "Configure repo-local overrides (config/autohub.env)"
  collect_listener_settings
  write_repo_file "$ENV_FILE" <<EOF
WIN_HOST=$WIN_HOST
WIN_PORT=$WIN_PORT
WIN_PATH=$WIN_PATH
CURL_TIMEOUT=$CURL_TIMEOUT
EOF
  echo "Wrote $ENV_FILE"
}

capture_allow_list() {
  local entries=()
  echo "Enter IPv4/CIDR entries for clients.allow (blank line to finish):"
  while true; do
    read -r line
    [[ -z $line ]] && break
    entries+=("$line")
  done
  if (( ${#entries[@]} == 0 )); then
    return 1
  fi
  printf '%s\n' "${entries[@]}"
}

configure_allow_list() {
  step "Configure nftables allow-list (config/clients.allow)"
  if [[ -f $ALLOW_FILE ]] && prompt_yes_no "Reuse existing clients.allow?" Y; then
    echo "Keeping existing allow-list."
    return
  fi
  local data
  while true; do
    if data=$(capture_allow_list); then
      break
    fi
    echo "Please enter at least one address." >&2
  done
  write_repo_file "$ALLOW_FILE" <<EOF
# Generated by install.sh on $(date -Is)
$data
EOF
  echo "Wrote $ALLOW_FILE"
}

configure_system_conf() {
  step "Write /etc/autohub-usbip.conf"
  write_root_file "$SYSTEM_CONF" <<EOF
# Auto-generated by $(basename "$0") on $(date -Is)
AUT0HUB_ROOT=$AUTOHUB_ROOT
WIN_HOST=$WIN_HOST
WIN_PORT=$WIN_PORT
WIN_PATH=$WIN_PATH
CURL_TIMEOUT=$CURL_TIMEOUT
EOF
  echo "Wrote $SYSTEM_CONF"
}

install_units() {
  step "Install udev and systemd units"
  install -m 0644 "$AUTOHUB_ROOT/99-usbip-autohub.rules" /etc/udev/rules.d/99-usbip-autohub.rules
  install -m 0644 "$AUTOHUB_ROOT/usbip-autohub@.service" /etc/systemd/system/usbip-autohub@.service
  install -m 0644 "$AUTOHUB_ROOT/usbip-retrigger.service" /etc/systemd/system/usbip-retrigger.service
  install -m 0644 "$AUTOHUB_ROOT/usbip-allow-sync.service" /etc/systemd/system/usbip-allow-sync.service

  local tmp
  tmp=$(mktemp)
  sed "s|{{AUTOHUB_ROOT}}|$AUTOHUB_ROOT|g" "$AUTOHUB_ROOT/usbip-allow-sync.path" >"$tmp"
  install -m 0644 "$tmp" /etc/systemd/system/usbip-allow-sync.path
  rm -f "$tmp"

  systemctl daemon-reload
  systemctl enable --now usbip-retrigger.service
  systemctl enable --now usbip-allow-sync.service
  systemctl enable --now usbip-allow-sync.path
  udevadm control --reload-rules
}

sync_allow_list() {
  step "Run initial usbip allow-list sync"
  AUT0HUB_ROOT="$AUTOHUB_ROOT" "$AUTOHUB_ROOT/bin/usbip-allow-sync"
}

summary() {
  printf '\nInstallation complete!\n'
  cat <<EOF
- Repo path recorded as AUT0HUB_ROOT=$AUTOHUB_ROOT
- Listener overrides saved to $ENV_FILE and $SYSTEM_CONF
- nftables allow-list saved to $ALLOW_FILE (edit + save to trigger resync)
- Services enabled: usbip-retrigger, usbip-allow-sync.service, usbip-allow-sync.path

Next steps:
  * Plug in a non-hub USB device and watch 'journalctl -u usbip-autohub@* -f'
  * Verify Windows receives curl callbacks at ${WIN_HOST}:${WIN_PORT}${WIN_PATH}
EOF
}

main() {
  cat <<'EOF'
AutoHub Pi installer
====================
This script will:
  - Install required packages (optional)
  - Configure usbipd for IPv4-only operation
  - Capture listener settings + allow-list entries
  - Install udev/systemd units and run the initial nftables sync
EOF

  ensure_packages
  configure_usbipd
  configure_env_file
  configure_allow_list
  configure_system_conf
  install_units
  sync_allow_list
  summary
}

main "$@"
