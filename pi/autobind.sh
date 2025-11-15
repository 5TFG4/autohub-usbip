#!/usr/bin/env bash
# shellcheck disable=SC2086
set -euo pipefail

WIN_HOST=${WIN_HOST:-"192.168.1.2"}   # Windows listener IP or hostname
WIN_PORT=${WIN_PORT:-"59876"}
WIN_PATH=${WIN_PATH:-"/usb-event/"}
CURL_TIMEOUT=${CURL_TIMEOUT:-1}
LOG_TAG="usbip-autohub"

ID=${1:-}
if [[ -z "$ID" ]]; then
  logger -t "$LOG_TAG" -- "missing ACTION-BUSID argument"
  exit 1
fi

ACTION=${ID%%-*}
BUSID=${ID#*-}
SYS="/sys/bus/usb/devices/${BUSID}"

log(){ logger -t "$LOG_TAG" -- "$*"; }
notify(){
  curl -fsS -X POST "http://${WIN_HOST}:${WIN_PORT}${WIN_PATH}" \
    -d "action=${ACTION}&busid=${BUSID}" --max-time "$CURL_TIMEOUT"
}

# Skip USB hubs (class 0x09) to prevent recursive exports.
if [[ -f "${SYS}/bDeviceClass" ]]; then
  if [[ $(<"${SYS}/bDeviceClass") == "09" ]]; then
    log "skip hub ${BUSID}"
    exit 0
  fi
fi

case "$ACTION" in
  add)
    /usr/sbin/usbip bind -b "$BUSID" || log "bind ${BUSID} already bound"
    log "bound ${BUSID}"
    if ! notify; then
      log "notify add ${BUSID} failed"
    fi
    ;;
  remove)
    /usr/sbin/usbip unbind -b "$BUSID" || log "unbind ${BUSID} already free"
    log "unbound ${BUSID}"
    if ! notify; then
      log "notify remove ${BUSID} failed"
    fi
    ;;
  *)
    log "unsupported action ${ACTION}"
    exit 1
    ;;
 esac
