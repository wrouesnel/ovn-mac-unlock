#!/bin/bash
# Reconciles OVN logical switch ports for pods matching LABEL_SELECTOR so that:
#   - port_security is empty (no source MAC/IP filtering)
#   - "unknown" is in addresses (frames to MACs other than the pod's own are delivered, FDB learning on)
# kube-ovn-controller resets these on pod updates/resync, so we re-check every INTERVAL seconds.
set -uo pipefail

LABEL_SELECTOR=${LABEL_SELECTOR:-ovn-mac-unlock=true}
INTERVAL=${INTERVAL:-10}
TLS_DIR=${TLS_DIR:-/var/run/tls}
# ENABLE_SSL: "true", "false" or "auto" (probe tcp, then ssl).
ENABLE_SSL=${ENABLE_SSL:-auto}
NB_HOST=${OVN_NB_SERVICE_HOST:-ovn-nb.kube-system.svc}
NB_PORT=${OVN_NB_SERVICE_PORT:-6641}

log() { echo "$(date -u +%FT%TZ) $*"; }

NBCTL_ARGS=()
nbctl() { ovn-nbctl --timeout=10 "${NBCTL_ARGS[@]}" "$@"; }

tls_present() { [[ -s $TLS_DIR/key && -s $TLS_DIR/cert && -s $TLS_DIR/cacert ]]; }

try_db() {
  local mode=$1
  if [[ $mode == ssl ]]; then
    NBCTL_ARGS=(-p "$TLS_DIR/key" -c "$TLS_DIR/cert" -C "$TLS_DIR/cacert" "--db=ssl:[$NB_HOST]:$NB_PORT")
  else
    NBCTL_ARGS=("--db=tcp:[$NB_HOST]:$NB_PORT")
  fi
  ovn-nbctl --timeout=5 "${NBCTL_ARGS[@]}" get NB_Global . _uuid >/dev/null 2>&1
}

connect() {
  case $ENABLE_SSL in
    true)
      if ! tls_present; then
        log "ERROR: ENABLE_SSL=true but no key/cert/cacert in $TLS_DIR - is secret kube-system/kube-ovn-tls present and mounted?"
        return 1
      fi
      try_db ssl && { log "connected to NB at ssl:[$NB_HOST]:$NB_PORT (ENABLE_SSL=true)"; return 0; }
      log "ERROR: cannot reach NB at ssl:[$NB_HOST]:$NB_PORT with certs from $TLS_DIR"
      return 1 ;;
    false)
      try_db tcp && { log "connected to NB at tcp:[$NB_HOST]:$NB_PORT (ENABLE_SSL=false)"; return 0; }
      log "ERROR: cannot reach NB at tcp:[$NB_HOST]:$NB_PORT - if kube-ovn runs with ENABLE_SSL=true, set ENABLE_SSL=true (or auto) here"
      return 1 ;;
    *)
      if try_db tcp; then
        log "connected to NB at tcp:[$NB_HOST]:$NB_PORT (auto-detected: SSL off)"
        return 0
      fi
      if ! tls_present; then
        log "ERROR: NB not reachable over tcp:[$NB_HOST]:$NB_PORT and no certs in $TLS_DIR." \
            "If kube-ovn uses SSL (ENABLE_SSL=true on kube-ovn-controller), secret kube-system/kube-ovn-tls must exist so it can be mounted here."
        return 1
      fi
      if try_db ssl; then
        log "connected to NB at ssl:[$NB_HOST]:$NB_PORT (auto-detected: SSL on, certs from $TLS_DIR)"
        return 0
      fi
      log "ERROR: NB not reachable over tcp or ssl at [$NB_HOST]:$NB_PORT (certs present in $TLS_DIR)"
      return 1 ;;
  esac
}

reconcile_lsp() {
  local lsp=$1 ps addrs=() line has_unknown=0

  if ! ps=$(nbctl lsp-get-port-security "$lsp" 2>/dev/null); then
    # Not created yet, hostNetwork pod, or non-OVN pod.
    return 0
  fi
  while IFS= read -r line; do
    [[ -z $line ]] && continue
    if [[ $line == unknown ]]; then has_unknown=1; else addrs+=("$line"); fi
  done < <(nbctl lsp-get-addresses "$lsp")

  if [[ -n $ps ]]; then
    nbctl lsp-set-port-security "$lsp" && log "$lsp: cleared port_security (was: ${ps//$'\n'/, })"
  fi
  if (( ! has_unknown )); then
    nbctl lsp-set-addresses "$lsp" "${addrs[@]}" unknown && log "$lsp: added 'unknown' to addresses"
  fi
}

reconcile_all() {
  local pods lsp
  if ! nbctl get NB_Global . _uuid >/dev/null 2>&1; then
    log "ERROR: lost connection to NB, reconnecting"
    return 1
  fi
  if ! pods=$(kubectl get pods -A -l "$LABEL_SELECTOR" \
      -o jsonpath='{range .items[?(@.spec.nodeName)]}{.metadata.name}.{.metadata.namespace}{"\n"}{end}'); then
    log "ERROR: listing pods with selector $LABEL_SELECTOR failed"
    return 1
  fi
  while IFS= read -r lsp; do
    [[ -n $lsp ]] && reconcile_lsp "$lsp"
  done <<< "$pods"
}

main() {
  log "starting: selector=$LABEL_SELECTOR interval=${INTERVAL}s ENABLE_SSL=$ENABLE_SSL nb=[$NB_HOST]:$NB_PORT"
  until connect; do sleep 15; done
  while true; do
    if ! reconcile_all; then
      # Leader may have moved or certs rotated; re-probe.
      connect || true
    fi
    sleep "$INTERVAL"
  done
}

[[ ${BASH_SOURCE[0]} == "$0" ]] && main
