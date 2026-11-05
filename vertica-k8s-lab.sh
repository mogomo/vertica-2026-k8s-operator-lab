#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted remote shell snippets are intentional
#==============================================================================
#  vertica-k8s-lab.sh  —  Vertica Kubernetes Operator v26.3 production-readiness
#                         lab for a SINGLE Ubuntu workstation (kind + Docker)
#==============================================================================
#
#  WHAT THIS SCRIPT DOES
#  ---------------------
#   --install   Builds a self-contained lab: a 4-node "kind" Kubernetes cluster
#               (1 control-plane + 3 workers, all Docker containers), MinIO as
#               S3-compatible communal storage, the official VerticaDB operator
#               (Helm chart vertica-charts/verticadb-operator, 26.3.x) and an
#               Eon Mode VerticaDB (3-node K-safe primary subcluster) from the
#               official opentext/vertica-k8s 26.3 image.
#   --test      Runs an automated production-readiness test suite with PASS /
#               FAIL / WARN reporting, SQL workloads and performance metrics:
#               health, workload, performance, persistent storage, monitoring,
#               security, workload isolation, operator reconciliation,
#               self-healing, node failure, backup/restore (restore points +
#               full revive), scaling, final health + host-preservation check.
#   --status    Read-only dashboard of everything the lab created.
#   --info      Read-only live view: VerticaDB CRs (desired vs actual), all lab
#               pods (ready/status/restarts/node/IP), Vertica nodes mapped to
#               pods and K8s nodes, K-safety, license, operator events, PVCs,
#               CPU/RAM.  Add "--watch 5" to refresh every 5 s (screenshots).
#   --demo      Small SQL demo: drop/create table demo.city_temps, load 10
#               rows, query them via the service, inside EVERY Vertica pod
#               (kubectl exec ... vsql) and from the workstation via NodePort.
#   --cleanup   Removes EVERYTHING the script created (kind cluster, pods,
#               containers, images, volumes, networks, services, CRDs, tools,
#               state, kernel runtime settings, Docker if the script installed
#               it) and audits that nothing remains or restarts at boot.
#   --verify-clean
#               Stand-alone residue audit (run it again after a reboot).
#
#  WHO / WHERE TO RUN IT  (exact path and user)
#  -------------------------------------------
#   * Path  : /opt/vertica-k8s-lab/vertica-k8s-lab.sh
#   * User  : your normal Ubuntu administrator account (a member of the "sudo"
#             group, e.g. the account you log in with), invoking the script
#             through sudo.  Do NOT run it as "dbadmin" (the owner of the
#             existing host Vertica installation) and do not log in as root.
#
#     sudo mkdir -p /opt/vertica-k8s-lab
#     sudo cp vertica-k8s-lab.sh /opt/vertica-k8s-lab/
#     sudo chmod 0750 /opt/vertica-k8s-lab/vertica-k8s-lab.sh
#     # optional (recommended) - your Vertica license file:
#     sudo cp vertica_license.dat /opt/vertica-k8s-lab/vertica_license.dat
#     sudo chmod 0600 /opt/vertica-k8s-lab/vertica_license.dat
#
#     cd /opt/vertica-k8s-lab
#     sudo ./vertica-k8s-lab.sh --install          # ~20-40 min (image downloads)
#     sudo ./vertica-k8s-lab.sh --test             # ~45-90 min full suite
#     sudo ./vertica-k8s-lab.sh --status
#     sudo ./vertica-k8s-lab.sh --info --watch 5   # live pods / Vertica view
#     sudo ./vertica-k8s-lab.sh --demo             # create table, load, query
#     sudo ./vertica-k8s-lab.sh --cleanup          # asks for confirmation
#     sudo reboot
#     sudo ./vertica-k8s-lab.sh --verify-clean     # proves nothing came back
#
#   Useful options:  --yes (no prompt) | --license FILE | --only g1,g2 |
#                    --skip g1,g2 | --keep-logs (cleanup) | --no-color | --help
#   Test groups:     health workload perf storage monitoring security isolation
#                    reconcile selfheal nodefail backup scaling final
#
#  PREREQUISITES
#  -------------
#   * Ubuntu 22.04 / 24.04 LTS (x86_64; arm64 best-effort), bash >= 4.4
#   * >= 24 GB *available* RAM (64 GB workstation recommended), >= 4 CPU cores,
#     >= 60 GB free disk on / (Docker root) and on /opt
#   * Internet access to: github.com, dl.k8s.io, get.helm.sh,
#     vertica.github.io, registry-1.docker.io / hub.docker.com, quay.io,
#     registry.k8s.io
#   * sudo rights.  Missing packages (curl, jq, ...) and Docker (docker.io) are
#     installed automatically and TRACKED, so --cleanup removes only what the
#     script itself installed.
#   * A Vertica license file is optional.  Without one the image's built-in
#     evaluation behaviour applies (26.x trial: max 3 nodes, 1 TB), and the
#     scaling tests use a separate small database to stay within 3 nodes.
#
#  WHAT IS NEVER TOUCHED (pre-existing host Vertica is preserved)
#  ----------------------------------------------------------------
#   * /opt/vertica, the dbadmin OS user, the host database, its ports
#     (5433/5434/5444/5450/8443/...), its systemd units and its kernel
#     settings.  The host installation is only *read* (version, running
#     processes, listening ports, config mtime) to prove it is unchanged.
#   * Lab ports bind to 127.0.0.1 only: 35433 (primary subcluster) and
#     35434 (secondary subcluster).  No lab component uses 5433 on the host.
#   * Pre-existing Docker, images, networks and volumes are left alone.
#   * Kernel parameters are raised at RUNTIME only (never written to
#     /etc/sysctl.*) and restored by --cleanup; a reboot resets them anyway.
#   * Nothing is enabled at boot: kind node containers get restart=no and a
#     script-installed Docker is not enabled at boot.
#
#  Environment overrides (advanced): see the "Configuration" section below.
#==============================================================================

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true
umask 077

readonly SCRIPT_VERSION="1.1.0"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
readonly SCRIPT_PATH
readonly SCRIPT_NAME="${SCRIPT_PATH##*/}"

#------------------------------------------------------------------------------
# Configuration (environment overrides)
#------------------------------------------------------------------------------
LAB_DIR="${LAB_DIR:-/opt/vertica-k8s-lab}"
TARGET_FROM_ENV="${VERTICA_TARGET_VERSION:+1}"
VERTICA_TARGET_VERSION="${VERTICA_TARGET_VERSION:-26.3}"   # e.g. 26.2 while 26.3 images are unpublished
VERTICA_IMAGE="${VERTICA_IMAGE:-}"                     # e.g. opentext/vertica-k8s:26.3.0-0-minimal
VERTICA_IMAGE_FLAVOR="${VERTICA_IMAGE_FLAVOR:-minimal}" # minimal | full
OPERATOR_CHART_VERSION="${OPERATOR_CHART_VERSION:-}"   # auto: newest 26.3.x chart
ALLOW_OPERATOR_FALLBACK="${ALLOW_OPERATOR_FALLBACK:-false}" # true => newest chart if no 26.3.x
VERSION_FALLBACK="${VERSION_FALLBACK:-true}"           # default 26.3 unpublished => use newest official release
MINIO_IMAGE="${MINIO_IMAGE:-}"                         # auto: first pullable candidate
KIND_VERSION="${KIND_VERSION:-v0.30.0}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.34.0@sha256:7416a61b42b1662ca6ca89f02028ac133a309a2a30ba309614e8ec94d976dc5a}"
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.34.0}"
HELM_VERSION="${HELM_VERSION:-v3.18.4}"
METRICS_SERVER_VERSION="${METRICS_SERVER_VERSION:-v0.7.2}"
VERTICA_LICENSE_FILE="${VERTICA_LICENSE_FILE:-}"       # auto: $LAB_DIR/vertica_license.dat if present
VERTICA_MAX_NODES="${VERTICA_MAX_NODES:-}"             # auto: 5 with license, 3 without
VDB_MEMORY_GB="${VDB_MEMORY_GB:-}"                     # per Vertica pod (auto)
VDB_CPU="${VDB_CPU:-}"                                 # per Vertica pod (auto)
HOST_RESERVE_GB="${HOST_RESERVE_GB:-8}"                # RAM kept free for host OS + host Vertica
SALES_ROWS="${SALES_ROWS:-}"                           # fact-table rows (auto)
ENABLE_DB_TLS="${ENABLE_DB_TLS:-true}"                 # operator-managed TLS (client + HTTPS/NMA)
ENABLE_INTERNODE_TLS="${ENABLE_INTERNODE_TLS:-true}"   # operator-managed internode TLS (Vertica 26.1+, VERIFY_CA)
ENABLE_OAUTH="${ENABLE_OAUTH:-true}"                   # Keycloak IdP + OAuth 2.0 / JWT machine-to-machine DB login
KEYCLOAK_IMAGE="${KEYCLOAK_IMAGE:-quay.io/keycloak/keycloak:26.7.5}"  # Keycloak = IdP officially tested by Vertica
ENABLE_MONITORING_STACK="${ENABLE_MONITORING_STACK:-false}" # chart Prometheus+Grafana (heavier)
NODE_FAIL_SECONDS="${NODE_FAIL_SECONDS:-60}"           # how long a worker stays "failed" (frozen)
LOAD_SECONDS="${LOAD_SECONDS:-60}"                     # client load generator length in failure tests
RECOVERY_TIMEOUT="${RECOVERY_TIMEOUT:-300}"            # time cap for every self-healing / recovery wait
SCALE_TIMEOUT="${SCALE_TIMEOUT:-600}"                  # time cap for each scaling step (T14)
DB_CREATE_TIMEOUT="${DB_CREATE_TIMEOUT:-2400}"         # seconds
HOST_PORT_PRIMARY="${HOST_PORT_PRIMARY:-35433}"
HOST_PORT_SECONDARY="${HOST_PORT_SECONDARY:-35434}"
DB_INIT_POLICY="${DB_INIT_POLICY:-CreateSkipPackageInstall}"

#------------------------------------------------------------------------------
# Fixed names (everything the lab creates carries one of these names/labels)
#------------------------------------------------------------------------------
readonly CLUSTER_NAME="vertica-lab"
readonly DOCKER_NET="vertica-lab-net"
readonly NS="vertica-lab"
readonly OP_NS="verticadb-operator"
readonly MINIO_NS="vertica-lab-minio"
readonly IDP_NS="vertica-lab-idp"
readonly IDP_REALM="vertica-lab"
readonly IDP_URL="http://keycloak.${IDP_NS}.svc.cluster.local:8080"
readonly IDP_ISSUER="${IDP_URL}/realms/${IDP_REALM}"
readonly OAUTH_RECORD="vlab_oauth_jwt"
readonly OAUTH_CLIENTS=(svc_etl svc_other svc_short)   # svc_etl = the ETL service; others = negative tests
readonly OP_RELEASE="vdb-op"
readonly CHART_REPO_NAME="vertica-charts"
readonly CHART_REPO_URL="https://vertica.github.io/charts"
readonly VDB="vdb"            # main (HA) VerticaDB CR
readonly DB_NAME="labdb"
readonly VDBE="vdbe"          # temporary elastic DB (trial-license scaling path)
readonly DBE_NAME="elasticdb"
readonly DB_USER="dbadmin"
readonly BUCKET="vertica-lab"
readonly CLIENT_POD="vlab-client-0"
readonly NODEPORT_PRIMARY=30433
readonly NODEPORT_SECONDARY=30434
readonly MINIO_ENDPOINT="http://minio.${MINIO_NS}.svc.cluster.local:9000"
readonly RP_ARCHIVE="lab_archive"
readonly LAB_TAG="vertica-k8s-lab"

BIN_DIR="$LAB_DIR/bin"; STATE_DIR="$LAB_DIR/state"; LOG_DIR="$LAB_DIR/logs"
REPORT_DIR="$LAB_DIR/reports"; MANIFEST_DIR="$LAB_DIR/manifests"
DL_DIR="$LAB_DIR/downloads"; CACHE_DIR="$LAB_DIR/cache"; TMPDIR_LAB="$LAB_DIR/tmp"
STATE_FILE="$STATE_DIR/lab.state"; SECRETS_FILE="$STATE_DIR/secrets.env"
KUBECONFIG_FILE="$STATE_DIR/kubeconfig"
readonly LAB_SUBDIRS=(bin state logs reports manifests downloads cache tmp)

KC=("$BIN_DIR/kubectl" --kubeconfig "$KUBECONFIG_FILE" --cache-dir "$CACHE_DIR/kube")

# runtime globals
MODE=""; ASSUME_YES=false; KEEP_LOGS=false; ONLY_GROUPS=""; SKIP_GROUPS=""
LOG_FILE=""; RUN_DIR=""; RUN_TS=""; STEP_NO=0; STEP_TOTAL=0; STEP_START=0
ARCH=""; WAIT_ELAPSED=0; WAIT_HOOK=""; EVENTS_SEEN_FILE=""
DB_PASSWORD=""; MINIO_ROOT_USER=""; MINIO_ROOT_PASSWORD=""; S3_ACCESS_KEY=""
S3_SECRET_KEY=""; LAB_USER_PASSWORD=""; KEYCLOAK_ADMIN_PASSWORD=""
OAUTH_SECRET_svc_etl=""; OAUTH_SECRET_svc_other=""; OAUTH_SECRET_svc_short=""
declare -a SECRET_VALUES=()
declare -a HOST_IPS=()
declare -a BG_PIDS=()

#==============================================================================
# UI / logging helpers  (designed to be readable in screenshots)
#==============================================================================
setup_ui() {
  IS_TTY=0; [[ -t 1 ]] && IS_TTY=1
  if [[ $IS_TTY == 1 && -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then
    C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'; C_RED=$'\e[31m'
    C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'; C_MAGENTA=$'\e[35m'
    C_CYAN=$'\e[36m'; C_WHITE=$'\e[97m'; C_BGBLUE=$'\e[44m'; C_BGRED=$'\e[41m'; C_BGGREEN=$'\e[42m'
  else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
    C_MAGENTA=""; C_CYAN=""; C_WHITE=""; C_BGBLUE=""; C_BGRED=""; C_BGGREEN=""
  fi
  if (locale charmap 2>/dev/null || echo "") | grep -qi 'utf-8'; then
    U_OK='✔'; U_FAIL='✖'; U_WARN='⚠'; U_INFO='ℹ'; U_ARROW='➜'; U_WAIT='⏳'
    U_K8S='⎈'; U_HL='━'; U_VL='│'; U_DB='◆'; U_BAR_OK='█'; U_BAR_FAIL='░'; U_MET='▸'
    U_CARD='┃'; U_THIN='─'; U_TIME='⏱'; U_DOT='●'
  else
    U_OK='OK'; U_FAIL='XX'; U_WARN='!!'; U_INFO='i'; U_ARROW='->'; U_WAIT='..'
    U_K8S='k8s'; U_HL='='; U_VL='|'; U_DB='*'; U_BAR_OK='#'; U_BAR_FAIL='.'; U_MET='>'
    U_CARD='|'; U_THIN='-'; U_TIME='~'; U_DOT='o'
  fi
  TERM_COLS=$(tput cols 2>/dev/null || echo 120); [[ $TERM_COLS =~ ^[0-9]+$ ]] || TERM_COLS=120
  if (( TERM_COLS < 80 )); then TERM_COLS=120; fi
}

_mask() {
  local s=$1 v
  for v in ${SECRET_VALUES[@]+"${SECRET_VALUES[@]}"}; do
    if [[ -n $v ]]; then s=${s//"$v"/********}; fi
  done
  for v in ${HOST_IPS[@]+"${HOST_IPS[@]}"}; do
    if [[ -n $v ]]; then s=${s//"$v"/<host-ip>}; fi
  done
  printf '%s' "$s"
}
# Privacy: the workstation's own LAN/WAN addresses are never printed or logged.
# Docker/kind bridge interfaces are excluded (their 172.x addresses are internal).
init_host_ip_mask() {
  HOST_IPS=()
  have ip || return 0
  local a
  while IFS= read -r a; do if [[ -n $a ]]; then HOST_IPS+=("$a"); fi; done < <(
    ip -o addr show scope global 2>/dev/null \
      | awk '$2 !~ /^(docker|br-|veth|kind|cni|flannel|virbr)/ {split($4, x, "/"); print x[1]}' \
      | awk '{ print length($0) " " $0 }' | sort -rn | cut -d' ' -f2- )
  return 0
}
_log() {
  if [[ -n ${LOG_FILE:-} && -w ${LOG_FILE%/*} ]]; then
    printf '%s | %s\n' "$(date '+%F %T')" "$(_mask "$*")" >>"$LOG_FILE"
  fi
  return 0
}
_hr() { local c=${1:-$U_HL} n=${2:-78} s=""; while (( ${#s} < n )); do s+="$c"; done; printf '%s' "$s"; }

banner() {
  local title=$1 sub=${2:-}
  printf '\n%s%s%s\n' "$C_BOLD$C_BLUE" "$(_hr)" "$C_RESET"
  printf '%s%s  %s  %s\n' "$C_BOLD$C_WHITE$C_BGBLUE" "" "$title" "$C_RESET"
  [[ -n $sub ]] && printf '%s  %s%s\n' "$C_DIM" "$sub" "$C_RESET"
  printf '%s%s%s\n' "$C_BOLD$C_BLUE" "$(_hr)" "$C_RESET"
  _log "==== $title ${sub:+($sub)}"
}
step() {
  STEP_NO=$((STEP_NO + 1)); STEP_START=$(date +%s)
  printf '\n%s%s STEP %d/%d %s %s%s   %s%s%s\n' "$C_BOLD$C_CYAN" "$U_HL$U_HL" "$STEP_NO" "$STEP_TOTAL" \
    "$U_HL$U_HL" "$1" "$C_RESET" "$C_DIM" "$(date '+%H:%M:%S')" "$C_RESET"
  _log "---- STEP $STEP_NO/$STEP_TOTAL: $1"
}
step_done() { ok "Step $STEP_NO finished in $(( $(date +%s) - STEP_START ))s"; }
what()   { printf '  %sWHAT%s %s\n' "$C_BOLD$C_CYAN" "$C_RESET" "$*"; _log "WHAT  $*"; }
why()    { printf '  %sWHY %s %s\n' "$C_BOLD$C_MAGENTA" "$C_RESET" "$*"; _log "WHY   $*"; }
info()   { printf '  %s%s%s %s\n' "$C_BLUE" "$U_INFO" "$C_RESET" "$(_mask "$*")"; _log "INFO  $*"; }
ok()     { printf '  %s%s%s %s\n' "$C_GREEN" "$U_OK" "$C_RESET" "$(_mask "$*")"; _log "OK    $*"; }
warn()   { printf '  %s%s %s%s\n' "$C_YELLOW" "$U_WARN" "$(_mask "$*")" "$C_RESET"; _log "WARN  $*"; }
err()    { printf '  %s%s %s%s\n' "$C_RED$C_BOLD" "$U_FAIL" "$(_mask "$*")" "$C_RESET" >&2; _log "ERROR $*"; }
detail() { printf '      %s%s%s\n' "$C_DIM" "$(_mask "$*")" "$C_RESET"; _log "      $*"; }
die()    { err "$*"; [[ -n ${LOG_FILE:-} ]] && err "Full log: $LOG_FILE"; exit 1; }
kv()     { printf '    %s%-30s%s %s\n' "$C_DIM" "$1" "$C_RESET" "$(_mask "${2:-}")"; _log "      $1 = ${2:-}"; }

_fmt_cmd() {
  local out="" a
  for a in "$@"; do
    case $a in
      kc) a="kubectl" ;; hm) a="helm" ;; kd) a="kind" ;;
      "$BIN_DIR/kubectl") a="kubectl" ;; "$BIN_DIR/helm") a="helm" ;; "$BIN_DIR/kind") a="kind" ;;
      --kubeconfig|--cache-dir) a="" ;;
      "$KUBECONFIG_FILE"|"$CACHE_DIR/kube") a="" ;;
    esac
    [[ -z $a ]] && continue
    [[ $a == *[[:space:]]* ]] && a="'$a'"
    out+="$a "
  done
  printf '%s' "${out% }"
}

# run [--show] [--allow-fail] [--label "short text"] cmd...   : prints the command, logs its output
#   --label: the screen shows the short text instead of a long command (e.g. a JSON patch); the log keeps the full command
run() {
  local show=0 allow=0 label=""
  while [[ ${1:-} == --show || ${1:-} == --allow-fail || ${1:-} == --label ]]; do
    case $1 in --show) show=1 ;; --allow-fail) allow=1 ;; --label) label=${2:-}; shift ;; esac; shift
  done
  local pretty; pretty=$(_mask "$(_fmt_cmd "$@")")
  if [[ -n $label ]]; then printf '    %s$ %s%s  %s(full command in the log)%s\n' "$C_DIM" "$(_mask "$label")" "$C_RESET" "$C_DIM" "$C_RESET"
  else printf '    %s$ %s%s\n' "$C_DIM" "$pretty" "$C_RESET"; fi
  _log "CMD   $pretty"
  local tmp rc=0
  tmp=$(mktemp "$TMPDIR_LAB/run.XXXXXX")
  "$@" >"$tmp" 2>&1 || rc=$?
  if [[ -n ${LOG_FILE:-} ]]; then _mask "$(cat "$tmp")" >>"$LOG_FILE"; printf '\n' >>"$LOG_FILE"; fi
  if (( show )) && [[ -s $tmp ]]; then
    while IFS= read -r l; do printf '      %s%s%s %s\n' "$C_DIM" "$U_VL" "$C_RESET" "$(_mask "$l")"; done <"$tmp"
  fi
  if (( rc != 0 )); then
    if (( allow )); then detail "(exit $rc tolerated)"
    else
      err "Command failed (exit $rc): $pretty"
      tail -n 25 "$tmp" | while IFS= read -r l; do printf '      %s %s\n' "$U_VL" "$(_mask "$l")" >&2; done
    fi
  fi
  rm -f "$tmp"
  return $rc
}

# run_live cmd... : streams output live (kind create, docker pull, helm)
run_live() {
  local pretty; pretty=$(_mask "$(_fmt_cmd "$@")")
  printf '    %s$ %s%s\n' "$C_DIM" "$pretty" "$C_RESET"; _log "CMD   $pretty"
  local had_e=0 rc; [[ $- == *e* ]] && had_e=1
  set +e
  "$@" 2>&1 | while IFS= read -r line; do
    _log "  | $line"; printf '      %s%s%s %s\n' "$C_DIM" "$U_VL" "$C_RESET" "$(_mask "$line")"
  done
  rc=${PIPESTATUS[0]}
  (( had_e )) && set -e
  (( rc != 0 )) && err "Command failed (exit $rc): $pretty"
  return "$rc"
}

_progress() { # desc elapsed status
  local msg="$U_WAIT $1 [${2}s] ${3:-}"
  local maxw=$(( TERM_COLS - 6 )); (( ${#msg} > maxw )) && msg="${msg:0:maxw}…"
  if (( IS_TTY )); then printf '\r\033[K    %s%s%s' "$C_YELLOW" "$msg" "$C_RESET"
  fi
}
_progress_clear() { (( IS_TTY )) && printf '\r\033[K'; return 0; }

# wait_until "description" timeout_s interval_s probe_fn [args...]
# probe_fn prints a short status text and returns 0 when the condition is met.
wait_until() {
  local desc=$1 timeout=$2 interval=$3; shift 3
  local start now el out rc last_commit=0
  start=$(date +%s)
  while :; do
    rc=0; out=$(trap - ERR; set +e; "$@" 2>>"${LOG_FILE:-/dev/null}") || rc=$?
    out=${out//$'\n'/ }
    now=$(date +%s); el=$((now - start))
    if [[ -n $WAIT_HOOK ]]; then _progress_clear; "$WAIT_HOOK" || true; fi
    if (( rc == 0 )); then
      _progress_clear; WAIT_ELAPSED=$el
      ok "$desc ${C_DIM}[${el}s]${C_RESET}${out:+ — $out}"; return 0
    fi
    if (( el >= timeout )); then
      _progress_clear; WAIT_ELAPSED=$el
      err "$desc — TIMEOUT after ${el}s (last state: ${out:-n/a})"; return 1
    fi
    _progress "$desc" "$el" "$out"; _log "WAIT  $desc [${el}s] $out"
    if (( IS_TTY == 0 && el - last_commit >= 30 )) || (( IS_TTY && el - last_commit >= 60 )); then
      _progress_clear; printf '    %s%s %s [%ss] %s%s\n' "$C_DIM" "$U_WAIT" "$desc" "$el" "$(_mask "$out")" "$C_RESET"
      last_commit=$el
    fi
    sleep "$interval"
  done
}

confirm() {
  $ASSUME_YES && return 0
  [[ -t 0 ]] || die "Confirmation required: re-run with --yes for non-interactive use."
  local ans; printf '\n  %s%s%s  Type %syes%s to continue: ' "$C_BOLD$C_YELLOW" "$1" "$C_RESET" "$C_BOLD" "$C_RESET"
  read -r ans; [[ $ans == yes ]]
}

#==============================================================================
# State, secrets, locking
#==============================================================================
state_get() {
  local k=$1 d=${2:-} v=""
  if [[ -f $STATE_FILE ]]; then v=$(grep -E "^${k}=" "$STATE_FILE" 2>/dev/null | tail -n1 | cut -d= -f2-) || true; fi
  printf '%s' "${v:-$d}"
}
state_set() {
  mkdir -p "$STATE_DIR"; touch "$STATE_FILE"; chmod 600 "$STATE_FILE"
  local tmp; tmp=$(mktemp "$STATE_DIR/.st.XXXXXX")
  grep -v -E "^${1}=" "$STATE_FILE" >"$tmp" 2>/dev/null || true
  printf '%s=%s\n' "$1" "$2" >>"$tmp"; mv "$tmp" "$STATE_FILE"; chmod 600 "$STATE_FILE"
}
state_set_once() { [[ -n $(state_get "$1") ]] || state_set "$1" "$2"; }
list_add() { local f="$STATE_DIR/$1"; touch "$f"; grep -qxF -- "$2" "$f" 2>/dev/null || printf '%s\n' "$2" >>"$f"; }

gen_pw() { head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-"${1:-24}"; }

load_secrets() {
  [[ -f $SECRETS_FILE ]] || return 0
  local k v
  while IFS='=' read -r k v; do
    case $k in
      DB_PASSWORD|MINIO_ROOT_PASSWORD|S3_SECRET_KEY|LAB_USER_PASSWORD|KEYCLOAK_ADMIN_PASSWORD|OAUTH_SECRET_svc_etl|OAUTH_SECRET_svc_other|OAUTH_SECRET_svc_short)
        printf -v "$k" '%s' "$v"; SECRET_VALUES+=("$v") ;;
      MINIO_ROOT_USER|S3_ACCESS_KEY) printf -v "$k" '%s' "$v" ;;
    esac
  done <"$SECRETS_FILE"
}
ensure_secrets() {
  if [[ ! -s $SECRETS_FILE ]]; then
    {
      printf 'DB_PASSWORD=%s\n' "$(gen_pw 24)"
      printf 'MINIO_ROOT_USER=vlab-root\n'
      printf 'MINIO_ROOT_PASSWORD=%s\n' "$(gen_pw 32)"
      printf 'S3_ACCESS_KEY=vertica-communal\n'
      printf 'S3_SECRET_KEY=%s\n' "$(gen_pw 32)"
      printf 'LAB_USER_PASSWORD=%s\n' "$(gen_pw 20)"
    } >"$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"
    ok "Generated random credentials -> $SECRETS_FILE (mode 600, root only)"
  fi
  # keys added in later script versions are appended to an existing file
  local k added=0
  for k in KEYCLOAK_ADMIN_PASSWORD OAUTH_SECRET_svc_etl OAUTH_SECRET_svc_other OAUTH_SECRET_svc_short; do
    grep -q "^$k=" "$SECRETS_FILE" || { printf '%s=%s\n' "$k" "$(gen_pw 32)" >>"$SECRETS_FILE"; added=1; }
  done
  (( added )) && ok "Added identity-provider credentials to $SECRETS_FILE"
  load_secrets
}

init_runtime() {
  local mode=$1
  mkdir -p "$LAB_DIR"
  local d; for d in "${LAB_SUBDIRS[@]}"; do mkdir -p "$LAB_DIR/$d"; done
  chmod 700 "$STATE_DIR"
  RUN_TS=$(date '+%Y%m%d-%H%M%S')
  RUN_DIR="$REPORT_DIR/$mode-$RUN_TS"; mkdir -p "$RUN_DIR"
  LOG_FILE="$LOG_DIR/$mode-$RUN_TS.log"; : >"$LOG_FILE"; chmod 600 "$LOG_FILE"
  EVENTS_SEEN_FILE="$RUN_DIR/.events-seen"; : >"$EVENTS_SEEN_FILE"
  exec 9>"$STATE_DIR/.lock"
  flock -n 9 || die "Another instance of $SCRIPT_NAME is running (lock $STATE_DIR/.lock)."
  load_secrets
  _log "$SCRIPT_NAME $SCRIPT_VERSION mode=$mode user=${SUDO_USER:-root} pid=$$"
}

#==============================================================================
# Traps / error handling
#==============================================================================
on_err() {
  local rc=$? line=$1 cmd=$2
  _progress_clear
  err "Unexpected failure (exit $rc) at line $line: $cmd"
  [[ -n ${LOG_FILE:-} ]] && err "Details in log: $LOG_FILE"
}
on_exit() {
  local rc=$?
  _progress_clear
  local p
  for p in ${BG_PIDS[@]+"${BG_PIDS[@]}"}; do kill "$p" 2>/dev/null || true; done
  if [[ $MODE == test ]]; then test_emergency_restore || true; fi
  [[ -n ${TMPDIR_LAB:-} && -d $TMPDIR_LAB ]] && find "$TMPDIR_LAB" -mindepth 1 -maxdepth 1 -name 'run.*' -delete 2>/dev/null || true
  if [[ -n ${LOG_FILE:-} && -f ${LOG_FILE:-/nonexistent} ]]; then
    printf '\n  %sLog file:%s %s\n' "$C_DIM" "$C_RESET" "$LOG_FILE"
  fi
  exit "$rc"
}
trap 'on_err $LINENO "$BASH_COMMAND"' ERR
trap on_exit EXIT
trap 'exit 130' INT TERM

#==============================================================================
# Tool wrappers
#==============================================================================
kc() { "${KC[@]}" "$@"; }
hm() {
  HELM_CONFIG_HOME="$CACHE_DIR/helm/config" HELM_CACHE_HOME="$CACHE_DIR/helm/cache" \
  HELM_DATA_HOME="$CACHE_DIR/helm/data" "$BIN_DIR/helm" --kubeconfig "$KUBECONFIG_FILE" "$@"
}
kd() { KIND_EXPERIMENTAL_DOCKER_NETWORK="$DOCKER_NET" "$BIN_DIR/kind" "$@"; }
have() { command -v "$1" >/dev/null 2>&1; }
docker_ok() { have docker && docker info >/dev/null 2>&1; }
cluster_exists() { [[ -x $BIN_DIR/kind ]] && docker_ok && kd get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; }
lab_containers() { { docker ps -a --filter "label=io.x-k8s.kind.cluster=$CLUSTER_NAME" --format '{{.Names}}' 2>/dev/null || true; } | sort; }
cp_node() { printf '%s-control-plane' "$CLUSTER_NAME"; }
k8s_reachable() { [[ -s $KUBECONFIG_FILE && -x $BIN_DIR/kubectl ]] && timeout 15 "${KC[@]}" get --raw=/readyz >/dev/null 2>&1; }

#==============================================================================
# SQL helpers (all SQL runs inside the lab client pod; the password is passed
# on stdin, never on a command line)
#==============================================================================
# vsql_as TIMEOUT FMT(raw|table) USER PASS HOST DB "SQL" [extra vsql args]
vsql_as() {
  local t=$1 fmt=$2 user=$3 pass=$4 host=$5 db=$6 sql=$7; shift 7
  _log "SQL   [$user@$host/$db] ${sql//$'\n'/ }"
  printf '%s\n%s\n' "$pass" "$sql" | timeout "$t" "${KC[@]}" exec -i -n "$NS" "${VSQL_POD:-$CLIENT_POD}" -c client -- \
    sh -c 'h=$1; d=$2; u=$3; f=$4; m=$5; shift 5
           IFS= read -r VSQL_PASSWORD; export VSQL_PASSWORD
           if [ "$f" = raw ]; then set -- -At "$@"; fi
           exec /opt/vertica/bin/vsql -X -q -m "$m" -v ON_ERROR_STOP=1 -h "$h" -d "$d" -U "$u" "$@"' \
    sh "$host" "$db" "$user" "$fmt" "${VSQL_SSLMODE:-prefer}" "$@"
}
vsql_c()   { vsql_as "${VSQL_TIMEOUT:-600}" raw "$DB_USER" "$DB_PASSWORD" "$@"; }
vsql_t()   { local t=$1; shift; vsql_as "$t" raw "$DB_USER" "$DB_PASSWORD" "$@"; }
# Pretty: shows the SQL and an aligned result table on screen (for screenshots)
vsql_show() {
  local host=$1 db=$2 title=$3 sql=$4 out rc=0
  printf '    %s%s SQL%s %s%s%s\n' "$C_BOLD$C_MAGENTA" "$U_DB" "$C_RESET" "$C_DIM" "$title" "$C_RESET"
  printf '%s\n' "$sql" | sed -e 's/^[[:space:]]*//' -e '/^$/d' | head -n 8 | while IFS= read -r l; do printf '      %s%s%s\n' "$C_MAGENTA" "$(_mask "$l")" "$C_RESET"; done
  out=$(vsql_as "${VSQL_TIMEOUT:-600}" table "$DB_USER" "$DB_PASSWORD" "$host" "$db" "$sql" 2>&1) || rc=$?
  _log "$out"
  printf '%s\n' "$out" | head -n 40 | while IFS= read -r l; do printf '      %s%s%s %s\n' "$C_DIM" "$U_VL" "$C_RESET" "$(_mask "$l")"; done
  return $rc
}
sql1() { vsql_c "$@" | head -n1 | tr -d '[:space:]'; }   # single scalar

#==============================================================================
# Host / preflight
#==============================================================================
require_root() {
  [[ $(uname -s) == Linux ]] || die "This script must run on Ubuntu Linux (detected $(uname -s))."
  (( EUID == 0 )) || die "Run with sudo:  sudo $SCRIPT_PATH --$MODE"
  if [[ ${SUDO_USER:-} == dbadmin && ${ALLOW_DBADMIN:-false} != true ]]; then
    die "Do not run as 'dbadmin' (owner of the host Vertica). Use your administrator account with sudo."
  fi
  (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) || die "bash >= 4.4 required"
}
detect_arch() {
  case $(uname -m) in
    x86_64|amd64) ARCH=amd64 ;; aarch64|arm64) ARCH=arm64 ;;
    *) die "Unsupported CPU architecture $(uname -m)" ;;
  esac
}
mem_kb() { awk -v k="$1" '$1==k":"{print $2}' /proc/meminfo; }
free_gb() { df -Pk "$1" 2>/dev/null | awk 'NR==2{print int($4/1048576)}'; }
port_in_use() { [[ -n $(ss -Hltn "( sport = :$1 )" 2>/dev/null) ]]; }

host_vertica_snapshot() {
  local v="none" procs="" ports="" mt="none" uid="none" unit="n/a"
  if [[ -x /opt/vertica/bin/vertica ]]; then
    v=$(timeout 20 /opt/vertica/bin/vertica --version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+-[0-9]+' | head -n1 || true)
    v=${v:-installed(version-unknown)}
  fi
  # Only processes in the HOST pid namespace: the lab's pods run /opt/vertica/bin/vertica too and are
  # visible from the host (kind nodes are containers) — they must not count as "host Vertica".
  local hostns p; hostns=$(readlink /proc/1/ns/pid 2>/dev/null || true)
  for p in $(pgrep -f '^/opt/vertica/bin/vertica ' 2>/dev/null | sort -n || true); do
    if [[ -n $hostns && $(readlink "/proc/$p/ns/pid" 2>/dev/null || true) == "$hostns" ]]; then procs+="$p,"; fi
  done
  ports=$(ss -Hltn 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -n | uniq \
          | grep -E '^(5433|5434|5444|5450|8443|4803|4804|6543)$' | tr '\n' ',' || true)
  [[ -f /opt/vertica/config/admintools.conf ]] && mt=$(stat -c %Y /opt/vertica/config/admintools.conf)
  uid=$(id -u dbadmin 2>/dev/null || echo none)
  unit=$(systemctl is-enabled verticad 2>/dev/null || echo n/a)
  printf 'host_vertica_version=%s\nhost_vertica_pids=%s\nhost_vertica_ports=%s\nadmintools_conf_mtime=%s\ndbadmin_uid=%s\nverticad_unit=%s\n' \
    "$v" "${procs:-none}" "${ports:-none}" "$mt" "$uid" "$unit"
}
show_host_snapshot() {
  local f=$1 k v
  while IFS='=' read -r k v; do kv "$k" "$v"; done <"$f"
}

preflight() {
  step "Pre-flight checks (OS, user, hardware, ports, host Vertica)"
  what "Validate the workstation can host the lab without disturbing the existing Vertica installation."
  why  "Fail fast with a clear message instead of half-installing on an unsuitable host."
  detect_arch
  local id="" ver=""
  if [[ -r /etc/os-release ]]; then id=$(. /etc/os-release; echo "${ID:-}"); ver=$(. /etc/os-release; echo "${VERSION_ID:-}"); fi
  kv "Operating system" "${id:-unknown} ${ver:-}"
  kv "Kernel / arch" "$(uname -r) / $ARCH"
  kv "Invoking user" "${SUDO_USER:-root} (via sudo, EUID=$EUID)"
  kv "Script path" "$SCRIPT_PATH"
  kv "Lab directory" "$LAB_DIR"
  [[ $id == ubuntu ]] || { [[ ${FORCE_NON_UBUNTU:-false} == true ]] || die "Ubuntu required (set FORCE_NON_UBUNTU=true to override)."; }
  [[ $ARCH == amd64 ]] || warn "arm64 detected: only '-multiarch' Vertica images support arm64."
  local total_kb avail_kb cpus
  total_kb=$(mem_kb MemTotal); avail_kb=$(mem_kb MemAvailable); cpus=$(nproc)
  kv "CPU cores" "$cpus"
  kv "RAM total / available" "$(( total_kb / 1048576 )) GB / $(( avail_kb / 1048576 )) GB"
  (( cpus >= 4 )) || die "At least 4 CPU cores are required."
  (( avail_kb / 1048576 >= 16 )) || die "At least 16 GB available RAM is required (24+ recommended)."
  local froot fopt; froot=$(free_gb /var/lib); fopt=$(free_gb "$LAB_DIR")
  kv "Free disk /var/lib (Docker)" "${froot} GB"; kv "Free disk $LAB_DIR" "${fopt} GB"
  (( froot >= 40 )) || die "Need >= 40 GB free under /var/lib for images and volumes."
  # ports (ignore if they belong to our own running cluster)
  local p
  for p in "$HOST_PORT_PRIMARY" "$HOST_PORT_SECONDARY"; do
    if port_in_use "$p" && ! docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -q "$(cp_node).*:$p->"; then
      die "Host port 127.0.0.1:$p is already in use. Set HOST_PORT_PRIMARY/HOST_PORT_SECONDARY to free ports."
    fi
    kv "Lab host port $p" "free / owned by lab"
  done
  info "Host Vertica (read-only inspection — nothing is modified):"
  host_vertica_snapshot >"$RUN_DIR/host-vertica-before.txt"
  show_host_snapshot "$RUN_DIR/host-vertica-before.txt"
  if grep -q 'host_vertica_ports=.*5433' "$RUN_DIR/host-vertica-before.txt"; then
    ok "Host Vertica listens on 5433 — the lab uses only 127.0.0.1:${HOST_PORT_PRIMARY}/${HOST_PORT_SECONDARY}, no conflict."
  fi
  if ! curl -fsS --max-time 15 -o /dev/null https://dl.k8s.io/release/stable.txt 2>/dev/null; then
    if have curl; then warn "Internet check to dl.k8s.io failed — downloads may fail."; fi
  else ok "Internet connectivity OK"; fi
  step_done
}

#==============================================================================
# Packages / Docker (tracked so cleanup removes only what we installed)
#==============================================================================
set_minus() { # lines of $1 that are not in $2 (order-independent)
  grep -Fxv -f <(printf '%s\n' "$2") <(printf '%s\n' "$1" | grep -v '^$') 2>/dev/null || true
}
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
apt_install_tracked() {
  local p missing=()
  for p in "$@"; do pkg_installed "$p" || missing+=("$p"); done
  (( ${#missing[@]} == 0 )) && return 0
  info "Installing missing packages: ${missing[*]} (recorded for cleanup)"
  local before after
  before=$(dpkg-query -W -f='${Package} ${Status}\n' 2>/dev/null | awk '/install ok installed/{print $1}' | sort)
  run env DEBIAN_FRONTEND=noninteractive apt-get update -y
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
  after=$(dpkg-query -W -f='${Package} ${Status}\n' 2>/dev/null | awk '/install ok installed/{print $1}' | sort)
  # newly installed = in "after" but not in "before" (order-independent; comm would demand identical collation)
  while IFS= read -r p; do
    if [[ -n $p ]]; then list_add apt-installed.txt "$p"; fi
  done < <(grep -Fxv -f <(printf '%s\n' "$before") <(printf '%s\n' "$after") || true)
  return 0
}

ensure_prereqs() {
  step "Host prerequisites (packages + Docker engine)"
  what "Ensure curl, jq, tar, iproute2, util-linux, procps and a Docker engine are available."
  why  "kind runs each Kubernetes node as a Docker container; jq/curl drive the automation."
  local need=()
  have curl  || need+=(curl ca-certificates)
  have jq    || need+=(jq)
  have tar   || need+=(tar)
  have gzip  || need+=(gzip)
  have ss    || need+=(iproute2)
  have flock || need+=(util-linux)
  have pgrep || need+=(procps)
  (( ${#need[@]} )) && apt_install_tracked "${need[@]}"
  ok "Base tools present: curl jq tar gzip ss flock pgrep"

  # Snapshot pre-existing Docker artefacts ONCE (first install)
  if [[ -z $(state_get DOCKER_PREEXISTING) ]]; then
    if have docker; then state_set DOCKER_PREEXISTING 1; else state_set DOCKER_PREEXISTING 0; fi
    local d; for d in /var/lib/docker /var/lib/containerd /etc/docker; do
      if [[ -e $d ]]; then list_add preexisting-paths.txt "$d"; fi
    done
    getent group docker >/dev/null && state_set DOCKER_GROUP_PREEXISTED 1 || state_set DOCKER_GROUP_PREEXISTED 0
    [[ -d /root/.docker ]] && state_set ROOT_DOCKER_DIR_PREEXISTED 1 || state_set ROOT_DOCKER_DIR_PREEXISTED 0
  fi

  if have docker && [[ $(state_get DOCKER_PREEXISTING) == 0 ]]; then
    # Docker was installed by an earlier (possibly interrupted) run of this lab
    state_set DOCKER_INSTALLED_BY_LAB 1
    docker info >/dev/null 2>&1 || run systemctl start docker
    run --allow-fail systemctl disable docker.service docker.socket
    ok "Docker engine $(docker version --format '{{.Server.Version}}' 2>/dev/null) (installed by this lab earlier; boot autostart disabled)"
  elif have docker; then
    if ! docker info >/dev/null 2>&1; then
      warn "Docker is installed but not running — starting it (cleanup will stop it again)."
      state_set_once DOCKER_WAS_STOPPED 1
      run systemctl start docker
    fi
    ok "Docker engine: $(docker version --format '{{.Server.Version}}' 2>/dev/null) ($( [[ $(state_get DOCKER_PREEXISTING) == 1 ]] && echo pre-existing, left untouched || echo installed by this lab))"
  else
    info "Docker not found — installing Ubuntu package docker.io (tracked; removed by --cleanup)."
    apt_install_tracked docker.io
    state_set DOCKER_INSTALLED_BY_LAB 1
    run systemctl start docker
    # resource-aware: do not start Docker automatically at boot
    run --allow-fail systemctl disable docker.service docker.socket
    ok "Docker installed: $(docker version --format '{{.Server.Version}}'); boot autostart disabled"
  fi
  docker_ok || die "Docker daemon is not usable."
  # snapshot pre-existing images ONCE
  if [[ ! -f $STATE_DIR/preexisting-images.txt ]]; then
    docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | sort -u >"$STATE_DIR/preexisting-images.txt" || true
    docker images --digests --format '{{.Repository}}@{{.Digest}}' 2>/dev/null | grep -v '<none>' | sort -u >>"$STATE_DIR/preexisting-images.txt" || true
    ok "Recorded $(wc -l <"$STATE_DIR/preexisting-images.txt") pre-existing image references (never removed)"
  fi
  if docker network inspect "$DOCKER_NET" >/dev/null 2>&1; then state_set_once DOCKER_NET_PREEXISTED 1; else state_set_once DOCKER_NET_PREEXISTED 0; fi
  step_done
}

#==============================================================================
# Kernel runtime parameters (never persisted)
#==============================================================================
set_sysctl_min() {
  local k=$1 want=$2 cur key; key="SYSCTL_${k//./_}"
  cur=$(sysctl -n "$k" 2>/dev/null || echo 0)
  if (( cur >= want )); then ok "$k = $cur (already >= $want, unchanged)"; return 0; fi
  state_set_once "${key}_ORIG" "$cur"; state_set "${key}_SET" "$want"
  run sysctl -w "$k=$want"
  ok "$k raised $cur -> $want (runtime only; reverts at reboot / --cleanup)"
}
tune_kernel() {
  step "Kernel runtime parameters (non-persistent)"
  what "Raise inotify limits (kind multi-node) and vm.max_map_count (Vertica requirement)."
  why  "Vertica docs: vm.max_map_count >= max(65536, RAM_KB/16) on every Kubernetes node; kind nodes share the host kernel."
  local need=$(( $(mem_kb MemTotal) / 16 )); (( need < 65536 )) && need=65536
  set_sysctl_min fs.inotify.max_user_watches 524288
  set_sysctl_min fs.inotify.max_user_instances 512
  set_sysctl_min vm.max_map_count "$need"
  info "Nothing is written to /etc/sysctl.conf or /etc/sysctl.d — host Vertica settings stay as they are."
  step_done
}

#==============================================================================
# CLI tools (kind, kubectl, helm) with checksum verification
#==============================================================================
download() { run curl -fsSL --retry 3 --retry-delay 3 --connect-timeout 20 -o "$2" "$1"; }
verify_sha256() {
  local file=$1 expected=$2 actual; actual=$(sha256sum "$file" | awk '{print $1}')
  [[ -n $expected && $actual == "$expected" ]] || die "SHA-256 mismatch for $file (expected ${expected:-?}, got $actual)"
  ok "SHA-256 verified ${C_DIM}${actual:0:20}…${C_RESET}"
}
install_tools() {
  step "Kubernetes CLI tools (kind $KIND_VERSION, kubectl $KUBECTL_VERSION, helm $HELM_VERSION)"
  what "Download pinned, checksum-verified binaries into $BIN_DIR (not on the system PATH)."
  why  "Self-contained tooling: nothing is added to /usr/local/bin; cleanup deletes the directory."
  local dl
  if [[ -x $BIN_DIR/kind ]] && "$BIN_DIR/kind" version 2>/dev/null | grep -q "$KIND_VERSION"; then ok "kind $KIND_VERSION already present"
  else
    dl="$DL_DIR/kind-$KIND_VERSION"; mkdir -p "$dl"
    download "https://github.com/kubernetes-sigs/kind/releases/download/$KIND_VERSION/kind-linux-$ARCH" "$dl/kind"
    download "https://github.com/kubernetes-sigs/kind/releases/download/$KIND_VERSION/kind-linux-$ARCH.sha256sum" "$dl/kind.sha256"
    verify_sha256 "$dl/kind" "$(awk '{print $1}' "$dl/kind.sha256")"
    install -m 0755 "$dl/kind" "$BIN_DIR/kind"; ok "kind installed: $("$BIN_DIR/kind" version)"
  fi
  if [[ -x $BIN_DIR/kubectl ]] && "$BIN_DIR/kubectl" version --client -o json 2>/dev/null | jq -e --arg v "$KUBECTL_VERSION" '.clientVersion.gitVersion==$v' >/dev/null; then ok "kubectl $KUBECTL_VERSION already present"
  else
    dl="$DL_DIR/kubectl-$KUBECTL_VERSION"; mkdir -p "$dl"
    download "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/$ARCH/kubectl" "$dl/kubectl"
    download "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/$ARCH/kubectl.sha256" "$dl/kubectl.sha256"
    verify_sha256 "$dl/kubectl" "$(tr -d '[:space:]' <"$dl/kubectl.sha256")"
    install -m 0755 "$dl/kubectl" "$BIN_DIR/kubectl"; ok "kubectl installed: $KUBECTL_VERSION"
  fi
  if [[ -x $BIN_DIR/helm ]] && "$BIN_DIR/helm" version --short 2>/dev/null | grep -q "^$HELM_VERSION"; then ok "helm $HELM_VERSION already present"
  else
    dl="$DL_DIR/helm-$HELM_VERSION"; mkdir -p "$dl"
    local tgz="helm-$HELM_VERSION-linux-$ARCH.tar.gz"
    download "https://get.helm.sh/$tgz" "$dl/$tgz"
    download "https://get.helm.sh/$tgz.sha256sum" "$dl/$tgz.sha256sum"
    verify_sha256 "$dl/$tgz" "$(awk '{print $1}' "$dl/$tgz.sha256sum")"
    mkdir -p "$dl/x"; tar -xzf "$dl/$tgz" -C "$dl/x"
    install -m 0755 "$dl/x/linux-$ARCH/helm" "$BIN_DIR/helm"; ok "helm installed: $("$BIN_DIR/helm" version --short)"
  fi
  step_done
}

#==============================================================================
# Image resolution & tracked pulls
#==============================================================================
image_present() { docker image inspect "$1" >/dev/null 2>&1; }
pull_tracked() {
  local img=$1
  if image_present "$img"; then
    if grep -qxF -- "$img" "$STATE_DIR/preexisting-images.txt" 2>/dev/null; then ok "Image $img present (pre-existing — will be preserved)"
    else ok "Image $img already pulled by the lab"; list_add lab-images.txt "$img"; fi
    return 0
  fi
  info "Pulling $img (first time can take several minutes)…"
  run_live docker pull "$img" || return 1
  list_add lab-images.txt "$img"
}
resolve_vertica_image() {
  local cached; cached=$(state_get VERTICA_IMAGE_RESOLVED)
  if [[ -n $VERTICA_IMAGE ]]; then cached=$VERTICA_IMAGE; fi
  if [[ -n $cached ]]; then pull_tracked "$cached"; state_set VERTICA_IMAGE_RESOLVED "$cached"; return 0; fi
  local repo="opentext/vertica-k8s" host_ver="" tags="" re cands=() t
  host_ver=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+-[0-9]+' "$RUN_DIR/host-vertica-before.txt" 2>/dev/null | head -n1 || true)
  info "Querying Docker Hub for $repo tags matching $VERTICA_TARGET_VERSION.x (host Vertica: ${host_ver:-unknown})"
  tags=$(curl -fsS --max-time 30 "https://hub.docker.com/v2/repositories/$repo/tags?page_size=100&name=${VERTICA_TARGET_VERSION}." 2>/dev/null \
         | jq -r '.results[]?.name' 2>/dev/null || true)
  re="^${VERTICA_TARGET_VERSION//./\\.}\\.[0-9]+-[0-9]+"
  if [[ $ARCH == arm64 ]]; then tags=$(grep -E "${re}.*multiarch" <<<"$tags" || true)
  elif [[ $VERTICA_IMAGE_FLAVOR == minimal ]]; then tags=$(grep -E "${re}-minimal$" <<<"$tags" || true)
  else tags=$(grep -E "${re}$" <<<"$tags" || true); fi
  if [[ -n $host_ver ]]; then
    for t in $tags; do if [[ $t == "$host_ver"* ]]; then cands+=("$repo:$t"); fi; done
  fi
  for t in $(sort -rV <<<"$tags"); do cands+=("$repo:$t"); done
  local suffix=""; [[ $VERTICA_IMAGE_FLAVOR == minimal ]] && suffix="-minimal"
  cands+=("$repo:${VERTICA_TARGET_VERSION}.0-0${suffix}" "$repo:${VERTICA_TARGET_VERSION}.0-0" "$repo:${VERTICA_TARGET_VERSION}.0-0-minimal")
  for t in "${cands[@]}"; do
    if pull_tracked "$t" 2>/dev/null; then state_set VERTICA_IMAGE_RESOLVED "$t"; ok "Vertica server image: $t"; return 0; fi
    warn "Could not pull $t — trying next candidate"
  done
  local recent; recent=$(curl -fsS --max-time 30 "https://hub.docker.com/v2/repositories/$repo/tags?page_size=100&ordering=last_updated" 2>/dev/null | jq -r '.results[]?.name' 2>/dev/null || true)
  info "Newest published tags: $(head -n 6 <<<"$recent" | tr '\n' ' ')"
  # Automatic fallback (only when the version was NOT chosen explicitly): use the newest published
  # official release instead of failing. VERTICA_TARGET_VERSION=26.3 (explicit) keeps the strict behaviour.
  if [[ -z $TARGET_FROM_ENV && $VERSION_FALLBACK == true ]]; then
    local fre='^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$' newest
    if [[ $ARCH == arm64 ]]; then fre='^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-multiarch$'
    elif [[ $VERTICA_IMAGE_FLAVOR == minimal ]]; then fre='^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-minimal$'; fi
    newest=$(grep -E "$fre" <<<"$recent" | sort -V | tail -n1 || true)
    if [[ -n $newest ]]; then
      local nv; nv=$(grep -oE '^[0-9]+\.[0-9]+' <<<"$newest")
      warn "Vertica $VERTICA_TARGET_VERSION container images are not published yet — falling back to the newest official release $repo:$newest"
      info "(set VERTICA_TARGET_VERSION=$VERTICA_TARGET_VERSION explicitly to disable this fallback; the operator chart follows the same version $nv.x)"
      if pull_tracked "$repo:$newest"; then
        VERTICA_TARGET_VERSION=$nv; state_set TARGET_VERSION "$nv"
        state_set VERTICA_IMAGE_RESOLVED "$repo:$newest"; ok "Vertica server image: $repo:$newest (Vertica $nv)"; return 0
      fi
    fi
  fi
  die "No pullable Vertica $VERTICA_TARGET_VERSION image found. Re-run with VERTICA_TARGET_VERSION=<published version> or VERTICA_IMAGE=repo:tag."
}
resolve_minio_image() {
  local cached; cached=$(state_get MINIO_IMAGE_RESOLVED); [[ -n $MINIO_IMAGE ]] && cached=$MINIO_IMAGE
  if [[ -n $cached ]]; then pull_tracked "$cached"; state_set MINIO_IMAGE_RESOLVED "$cached"; return 0; fi
  local c
  for c in quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z minio/minio:RELEASE.2025-09-07T16-13-09Z \
           quay.io/minio/minio:RELEASE.2025-04-22T22-12-26Z minio/minio:RELEASE.2025-04-22T22-12-26Z \
           minio/minio:RELEASE.2024-12-18T13-15-44Z cgr.dev/chainguard/minio:latest; do
    if pull_tracked "$c" 2>/dev/null; then state_set MINIO_IMAGE_RESOLVED "$c"; ok "MinIO image: $c"; return 0; fi
    warn "MinIO candidate $c not pullable — trying next"
  done
  die "No MinIO image could be pulled. Set MINIO_IMAGE=<any S3-compatible MinIO image>."
}
resolve_images() {
  step "Container images (official Vertica $VERTICA_TARGET_VERSION server image, MinIO, kind node)"
  what "Resolve exact image tags, pull them into Docker and record them for cleanup."
  why  "Pinned tags make the lab reproducible; pre-existing images are never deleted."
  pull_tracked "$KIND_NODE_IMAGE"
  resolve_vertica_image
  resolve_minio_image
  if [[ $ENABLE_OAUTH == true ]]; then pull_tracked "$KEYCLOAK_IMAGE" && ok "Identity provider image: $KEYCLOAK_IMAGE"; fi
  step_done
}

#==============================================================================
# kind cluster
#==============================================================================
write_kind_config() {
  cat >"$MANIFEST_DIR/kind-config.yaml" <<EOF
# kind cluster for $LAB_TAG — 1 control-plane (infra) + 3 workers (Vertica)
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: $CLUSTER_NAME
networking:
  apiServerAddress: "127.0.0.1"
nodes:
- role: control-plane
  image: $KIND_NODE_IMAGE
  labels:
    vertica-lab/role: infra
  extraPortMappings:
  - containerPort: $NODEPORT_PRIMARY
    hostPort: $HOST_PORT_PRIMARY
    listenAddress: "127.0.0.1"
    protocol: TCP
  - containerPort: $NODEPORT_SECONDARY
    hostPort: $HOST_PORT_SECONDARY
    listenAddress: "127.0.0.1"
    protocol: TCP
- role: worker
  image: $KIND_NODE_IMAGE
  labels:
    vertica-lab/role: db
- role: worker
  image: $KIND_NODE_IMAGE
  labels:
    vertica-lab/role: db
- role: worker
  image: $KIND_NODE_IMAGE
  labels:
    vertica-lab/role: db
EOF
}
disable_node_autostart() {
  local c
  for c in $(lab_containers); do docker update --restart=no "$c" >/dev/null; done
  ok "kind node containers set to restart=no (nothing auto-starts after an Ubuntu reboot)"
}
record_lab_volumes() {
  local c
  for c in $(lab_containers); do
    docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' "$c" 2>/dev/null \
      | while IFS= read -r v; do if [[ -n $v ]]; then list_add lab-volumes.txt "$v"; fi; done
  done
  return 0
}
start_stopped_nodes() {
  local c st started=0
  for c in "$(cp_node)" $(lab_containers | grep -v control-plane); do
    st=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)
    case $st in
      running) : ;;
      paused) run docker unpause "$c"; started=1 ;;
      exited|created) run docker start "$c"; started=1 ;;
      missing) warn "Node container $c missing" ;;
    esac
  done
  (( started )) && info "Restarted stopped kind nodes (e.g. after a reboot) — Kubernetes and the operator will recover the database."
  return 0
}
nodes_ready_probe() {
  local r t
  r=$(kc get nodes -o json 2>/dev/null | jq '[.items[] | select(any(.status.conditions[]; .type=="Ready" and .status=="True"))] | length' 2>/dev/null || echo 0)
  t=$(kc get nodes --no-headers 2>/dev/null | wc -l || echo 0)
  printf 'nodes Ready %s/4' "$r"; [[ $r -ge 4 && $t -ge 4 ]]
}
create_cluster() {
  step "Kubernetes cluster (kind '$CLUSTER_NAME': 1 control-plane + 3 workers)"
  what "Create (or restart) a 4-node Kubernetes cluster where every node is a Docker container."
  why  "Three workers let us demonstrate pod anti-affinity, K-safety and node failure on one workstation."
  write_kind_config
  if cluster_exists; then
    ok "kind cluster '$CLUSTER_NAME' already exists — reusing it (idempotent)"
    start_stopped_nodes
    run kd export kubeconfig --name "$CLUSTER_NAME" --kubeconfig "$KUBECONFIG_FILE"
  else
    info "Creating cluster — kind prints its own progress below:"
    run_live kd create cluster --config "$MANIFEST_DIR/kind-config.yaml" --kubeconfig "$KUBECONFIG_FILE" --wait 10m
    list_add lab-images.txt "$KIND_NODE_IMAGE"
  fi
  chmod 600 "$KUBECONFIG_FILE"
  disable_node_autostart
  record_lab_volumes
  wait_until "Kubernetes nodes Ready" 600 5 nodes_ready_probe
  run --show kc get nodes -o wide
  step_done
}
kind_load() {
  local img=$1 n missing=0
  for n in $(lab_containers); do
    docker exec "$n" crictl inspecti "$img" >/dev/null 2>&1 || { missing=1; break; }
  done
  if (( missing == 0 )); then ok "Image already loaded on all nodes: $img"; return 0; fi
  info "Loading $img into all kind nodes (avoids registry pulls inside the cluster)…"
  if run --allow-fail kd load docker-image "$img" --name "$CLUSTER_NAME"; then ok "Loaded $img"; return 0; fi
  # Multi-platform images + Docker's containerd image store: 'docker save' exports only the host
  # platform, which 'ctr import --all-platforms' rejects. Retry with a single-platform archive.
  local tar="$TMPDIR_LAB/img-$$.tar"
  info "Retrying with a single-platform archive (linux/$ARCH)…"
  if run --allow-fail docker save --platform "linux/$ARCH" -o "$tar" "$img" \
     && run --allow-fail kd load image-archive "$tar" --name "$CLUSTER_NAME"; then
    rm -f "$tar"; ok "Loaded $img (single-platform archive)"; return 0
  fi
  rm -f "$tar"
  warn "Could not pre-load $img — the kind nodes will pull it from the registry instead (needs internet)."
  return 0
}
load_images() {
  step "Pre-load images into the kind nodes"
  what "Copy the Vertica and MinIO images from the host Docker cache into every node's containerd."
  why  "Faster, reliable pod starts and no Docker Hub rate-limit surprises during failover tests."
  kind_load "$(state_get VERTICA_IMAGE_RESOLVED)"
  kind_load "$(state_get MINIO_IMAGE_RESOLVED)"
  if [[ $ENABLE_OAUTH == true ]]; then kind_load "$KEYCLOAK_IMAGE"; fi
  step_done
}

#==============================================================================
# Cluster add-ons, namespaces, RBAC
#==============================================================================
install_addons() {
  step "Cluster add-ons: metrics-server, namespaces, Pod Security labels, RBAC"
  what "Install metrics-server (kubectl top) and create lab namespaces + least-privilege accounts."
  why  "Monitoring needs resource metrics; namespaces/RBAC demonstrate tenant isolation."
  local f="$DL_DIR/metrics-server-$METRICS_SERVER_VERSION.yaml"
  [[ -s $f ]] || download "https://github.com/kubernetes-sigs/metrics-server/releases/download/$METRICS_SERVER_VERSION/components.yaml" "$f"
  run kc apply -f "$f"
  if ! kc -n kube-system get deploy metrics-server -o json | jq -e '.spec.template.spec.containers[0].args | index("--kubelet-insecure-tls")' >/dev/null; then
    run kc -n kube-system patch deploy metrics-server --type=json \
      -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
  fi
  cat >"$MANIFEST_DIR/namespaces.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
  labels:
    vertica-lab/managed: "true"
    pod-security.kubernetes.io/warn: baseline
    pod-security.kubernetes.io/audit: baseline
---
apiVersion: v1
kind: Namespace
metadata:
  name: $MINIO_NS
  labels:
    vertica-lab/managed: "true"
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata: {name: vlab-client, namespace: $NS}
---
apiVersion: v1
kind: ServiceAccount
metadata: {name: vlab-readonly, namespace: $NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: vlab-readonly, namespace: $NS}
rules:
- apiGroups: [""]
  resources: [pods, services]
  verbs: [get, list, watch]
- apiGroups: [vertica.com]
  resources: [verticadbs]
  verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: vlab-readonly, namespace: $NS}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: vlab-readonly}
subjects:
- {kind: ServiceAccount, name: vlab-readonly, namespace: $NS}
EOF
  run kc apply -f "$MANIFEST_DIR/namespaces.yaml"
  step_done
}

#==============================================================================
# MinIO (S3-compatible communal storage)
#==============================================================================
apply_secret_env() { # ns name envfile
  kc create secret generic "$2" -n "$1" --from-env-file="$3" --dry-run=client -o yaml | kc apply -f - >/dev/null
}
minio_probe() {
  local r; r=$(kc -n "$MINIO_NS" get deploy minio -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
  printf 'MinIO ready replicas: %s/1' "${r:-0}"; [[ ${r:-0} -ge 1 ]]
}
minio_has_mc() { kc -n "$MINIO_NS" exec deploy/minio -- sh -c 'command -v mc' >/dev/null 2>&1; }
s3_put_bucket_via_node() {
  local ip code; ip=$(kc -n "$MINIO_NS" get svc minio -o jsonpath='{.spec.clusterIP}')
  code=$(printf 'user = "%s:%s"\n' "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" | docker exec -i "$(cp_node)" \
         curl -sS -K - --aws-sigv4 "aws:amz:us-east-1:s3" -o /dev/null -w '%{http_code}' -X PUT "http://$ip:9000/$BUCKET" || echo 000)
  [[ $code == 200 || $code == 409 ]]
}
deploy_minio() {
  step "Communal storage: MinIO (S3-compatible) for Eon Mode"
  what "Deploy a MinIO object store on the control-plane node with a persistent volume and bucket '$BUCKET'."
  why  "Eon Mode keeps the authoritative copy of data in communal (S3) storage — enables revive, scaling and DR."
  local envf="$TMPDIR_LAB/minio.env"
  printf 'MINIO_ROOT_USER=%s\nMINIO_ROOT_PASSWORD=%s\n' "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >"$envf"
  apply_secret_env "$MINIO_NS" minio-root "$envf"; rm -f "$envf"
  cat >"$MANIFEST_DIR/minio.yaml" <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: minio-data, namespace: $MINIO_NS}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: standard
  resources: {requests: {storage: 40Gi}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: minio, namespace: $MINIO_NS, labels: {app: minio}}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: minio}}
  template:
    metadata: {labels: {app: minio}}
    spec:
      nodeSelector: {node-role.kubernetes.io/control-plane: ""}
      tolerations:
      - {key: node-role.kubernetes.io/control-plane, operator: Exists, effect: NoSchedule}
      securityContext: {runAsUser: 1000, runAsGroup: 1000, runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}
      containers:
      - name: minio
        image: $(state_get MINIO_IMAGE_RESOLVED)
        imagePullPolicy: IfNotPresent
        args: ["server", "/data", "--console-address", ":9001"]
        env:
        - name: MINIO_ROOT_USER
          valueFrom: {secretKeyRef: {name: minio-root, key: MINIO_ROOT_USER}}
        - name: MINIO_ROOT_PASSWORD
          valueFrom: {secretKeyRef: {name: minio-root, key: MINIO_ROOT_PASSWORD}}
        - name: MC_HOST_local
          value: "http://\$(MINIO_ROOT_USER):\$(MINIO_ROOT_PASSWORD)@127.0.0.1:9000"
        - {name: HOME, value: /tmp}
        ports:
        - {containerPort: 9000, name: s3}
        - {containerPort: 9001, name: console}
        readinessProbe:
          httpGet: {path: /minio/health/ready, port: 9000}
          periodSeconds: 5
        livenessProbe:
          httpGet: {path: /minio/health/live, port: 9000}
          initialDelaySeconds: 20
          periodSeconds: 10
        resources:
          requests: {cpu: 250m, memory: 512Mi}
          limits: {cpu: "1", memory: 1Gi}
        securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
        volumeMounts:
        - {name: data, mountPath: /data}
      volumes:
      - name: data
        persistentVolumeClaim: {claimName: minio-data}
---
apiVersion: v1
kind: Service
metadata: {name: minio, namespace: $MINIO_NS}
spec:
  selector: {app: minio}
  ports:
  - {name: s3, port: 9000, targetPort: 9000}
EOF
  run kc apply -f "$MANIFEST_DIR/minio.yaml"
  wait_until "MinIO pod ready" 600 5 minio_probe
  local s3key=$MINIO_ROOT_USER s3sec=$MINIO_ROOT_PASSWORD
  if minio_has_mc; then
    state_set MINIO_MC 1
    run kc -n "$MINIO_NS" exec deploy/minio -- mc mb --ignore-existing "local/$BUCKET"
    # least-privilege S3 identity for Vertica (instead of the MinIO root user)
    if printf '%s\n' "$S3_SECRET_KEY" | kc -n "$MINIO_NS" exec -i deploy/minio -- sh -c 'IFS= read -r SK; mc admin user add local "$1" "$SK"' sh "$S3_ACCESS_KEY" >>"$LOG_FILE" 2>&1 \
       && { kc -n "$MINIO_NS" exec deploy/minio -- mc admin policy attach local readwrite --user "$S3_ACCESS_KEY" >>"$LOG_FILE" 2>&1 \
            || kc -n "$MINIO_NS" exec deploy/minio -- mc admin policy set local readwrite "user=$S3_ACCESS_KEY" >>"$LOG_FILE" 2>&1; }; then
      s3key=$S3_ACCESS_KEY; s3sec=$S3_SECRET_KEY
      ok "Dedicated MinIO identity '$S3_ACCESS_KEY' (readwrite policy) created for Vertica"
    else warn "Could not create a dedicated MinIO user — Vertica will use the MinIO root identity (lab only)."; fi
  else
    state_set MINIO_MC 0
    info "Image has no 'mc' client — creating bucket via S3 API (curl --aws-sigv4 from the control-plane node)"
    s3_put_bucket_via_node || die "Failed to create bucket $BUCKET"
  fi
  ok "Bucket s3://$BUCKET ready at $MINIO_ENDPOINT"
  state_set COMMUNAL_KEY_IS_ROOT "$([[ $s3key == "$MINIO_ROOT_USER" ]] && echo 1 || echo 0)"
  local cf="$TMPDIR_LAB/communal.env"
  printf 'accesskey=%s\nsecretkey=%s\n' "$s3key" "$s3sec" >"$cf"
  apply_secret_env "$NS" communal-creds "$cf"; rm -f "$cf"
  ok "Kubernetes Secret $NS/communal-creds (keys: accesskey, secretkey)"
  step_done
}

#==============================================================================
# VerticaDB operator (official Helm chart)
#==============================================================================
resolve_chart_version() {
  local v=$OPERATOR_CHART_VERSION
  if [[ -z $v ]]; then v=$(state_get OPERATOR_CHART_VERSION_RESOLVED); fi
  if [[ -z $v ]]; then
    local all; all=$(hm search repo "$CHART_REPO_NAME/verticadb-operator" --versions -o json 2>/dev/null || echo '[]')
    v=$(jq -r --arg t "$VERTICA_TARGET_VERSION" '.[] | select((.version|startswith($t)) or (.app_version|startswith($t))) | .version' <<<"$all" | sort -V | tail -n1)
    if [[ -z $v ]]; then
      info "Available operator chart versions: $(jq -r '.[].version' <<<"$all" | sort -rV | head -n 8 | tr '\n' ' ')"
      info "Tip: if $VERTICA_TARGET_VERSION is not published yet, re-run with VERTICA_TARGET_VERSION=<published version, e.g. 26.2>"
      if [[ $ALLOW_OPERATOR_FALLBACK == true ]]; then
        v=$(jq -r '.[].version' <<<"$all" | sort -V | tail -n1); warn "No $VERTICA_TARGET_VERSION.x chart — using newest $v (ALLOW_OPERATOR_FALLBACK=true)"
      else die "No verticadb-operator chart $VERTICA_TARGET_VERSION.x found. Set OPERATOR_CHART_VERSION or ALLOW_OPERATOR_FALLBACK=true."; fi
    fi
  fi
  state_set OPERATOR_CHART_VERSION_RESOLVED "$v"; printf '%s' "$v"
}
operator_probe() {
  local j r t; j=$(kc -n "$OP_NS" get deploy -o json 2>/dev/null || echo '{"items":[]}')
  t=$(jq '[.items[]] | length' <<<"$j"); r=$(jq '[.items[] | select((.status.availableReplicas // 0) >= 1)] | length' <<<"$j")
  printf 'operator deployments available %s/%s' "$r" "$t"; [[ $t -ge 1 && $r -ge $t ]]
}
install_operator() {
  step "VerticaDB operator $VERTICA_TARGET_VERSION.x (official Helm chart $CHART_REPO_URL)"
  what "helm repo add $CHART_REPO_NAME; helm upgrade --install $OP_RELEASE (webhook + controllers + CRDs)."
  why  "The operator automates create/revive/restart/scale/upgrade and validates CR changes via its admission webhook."
  run hm repo add "$CHART_REPO_NAME" "$CHART_REPO_URL" --force-update
  run hm repo update "$CHART_REPO_NAME"
  local ver; ver=$(resolve_chart_version)
  kv "Operator chart version" "$ver"
  local mon=""
  if [[ $ENABLE_MONITORING_STACK == true ]]; then
    mon=$'prometheusServer:\n  enabled: true\ngrafana:\n  enabled: true'
  fi
  cat >"$MANIFEST_DIR/operator-values.yaml" <<EOF
# values for $CHART_REPO_NAME/verticadb-operator ($LAB_TAG)
prometheus:
  expose: EnableWithAuth        # HTTPS /metrics protected by Kubernetes RBAC (production default)
  createProxyRBAC: true
logging:
  level: info
tolerations:
- key: node-role.kubernetes.io/control-plane
  operator: Exists
  effect: NoSchedule
affinity:
  nodeAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      preference:
        matchExpressions:
        - {key: node-role.kubernetes.io/control-plane, operator: Exists}
$mon
EOF
  # pre-pull + load operator images (and any sidecars) referenced by the chart
  local imgs img
  imgs=$(hm template "$OP_RELEASE" "$CHART_REPO_NAME/verticadb-operator" --version "$ver" -n "$OP_NS" -f "$MANIFEST_DIR/operator-values.yaml" 2>/dev/null \
         | grep -E '^[[:space:]]*(- )?image:' | sed -E "s/.*image:[[:space:]]*[\"']?([^\"' ]+)[\"']?.*/\\1/" | sort -u || true)
  for img in $imgs; do
    if pull_tracked "$img"; then kind_load "$img"; state_set OPERATOR_IMAGE "$img"; else warn "Could not pre-pull $img (cluster will pull it)"; fi
  done
  local cur; cur=$(hm list -n "$OP_NS" -o json 2>/dev/null | jq -r --arg r "$OP_RELEASE" '.[] | select(.name==$r) | .chart' || true)
  if [[ $cur == "verticadb-operator-$ver" ]]; then ok "Operator release $OP_RELEASE already at chart $ver (idempotent, not reinstalled)"
  else
    run_live hm upgrade --install "$OP_RELEASE" "$CHART_REPO_NAME/verticadb-operator" --version "$ver" \
      -n "$OP_NS" --create-namespace -f "$MANIFEST_DIR/operator-values.yaml" --timeout 10m
  fi
  wait_until "VerticaDB operator available" 900 5 operator_probe
  run --show kc -n "$OP_NS" get pods -o wide
  local crd; for crd in verticadbs.vertica.com verticarestorepointsqueries.vertica.com; do
    if kc get crd "$crd" >/dev/null 2>&1; then ok "CRD $crd installed"; else warn "CRD $crd not found"; fi
  done
  run --show --allow-fail kc get crd -o custom-columns=CRD:.metadata.name --no-headers -l app.kubernetes.io/name=verticadb-operator
  # RBAC: allow the lab client service account to read the operator /metrics endpoint
  local cr; cr=$(kc get clusterrole -o name 2>/dev/null | grep -E 'metrics-reader' | grep -i vertica | head -n1 | cut -d/ -f2 || true)
  if [[ -n $cr ]]; then
    kc create clusterrolebinding vlab-metrics-reader --clusterrole="$cr" --serviceaccount="$NS:vlab-client" --dry-run=client -o yaml | kc apply -f - >/dev/null
    state_set METRICS_READER_ROLE "$cr"; ok "ClusterRoleBinding vlab-metrics-reader -> $cr (for authenticated /metrics scraping)"
  else warn "metrics-reader ClusterRole not found; operator metrics test will be limited."; fi
  state_set OPERATOR_INSTALLED 1
  step_done
}

#==============================================================================
# VerticaDB rendering / deployment
#==============================================================================
render_affinity() { # vdbname mode(required|preferred) indent-prefix
  local n=$1 mode=$2
  # Only PRIMARY pods repel each other (one primary per worker = real K-safety across "hosts").
  # Secondary-subcluster pods (scaling test) may share workers with primaries.
  if [[ $mode == required ]]; then cat <<EOF
      podAntiAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector: {matchLabels: {vertica.com/subcluster-selector-name: $n-primary}}
          topologyKey: kubernetes.io/hostname
EOF
  else cat <<EOF
      podAntiAffinity:
        preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          podAffinityTerm:
            labelSelector: {matchLabels: {vertica-lab/db: $n}}
            topologyKey: kubernetes.io/hostname
EOF
  fi
}
# render_vdb name db path policy psize mem cpu svctype nodeport ksafety0 shards [rp_archive] [https_secret] [client_secret] [internode_secret]
render_vdb() {
  local name=$1 dbname=$2 cpath=$3 policy=$4 psize=$5 mem=$6 cpu=$7 svctype=$8 nodeport=$9 ks0=${10} shards=${11}
  local rp=${12:-} hsec=${13:-} csec=${14:-} isec=${15:-}
  local ann="    vertica.com/include-uid-in-path: \"false\""
  [[ $ks0 == true ]] && ann+=$'\n'"    vertica.com/k-safety: \"0\""
  [[ $policy == Revive ]] && ann+=$'\n'"    vertica.com/ignore-cluster-lease: \"true\""
  # Vertica 26.3 docs: "To revive a database with TLS enabled, add the annotation vertica.com/enable-tls-auth"
  [[ $policy == Revive && $ENABLE_DB_TLS == true ]] && ann+=$'\n'"    vertica.com/enable-tls-auth: \"true\""
  # Vertica 26.3 docs: enable-fallthrough lets a TLS login without a client certificate fall through to
  # password auth (the operator keeps using its certificate; plain-text logins stay rejected).
  [[ $ENABLE_DB_TLS == true ]] && ann+=$'\n'"    vertica.com/enable-fallthrough: \"true\""
  local lic=""; [[ -n $(state_get LICENSE_INSTALLED) ]] && lic="  licenseSecret: vdb-license"
  local rpb=""; [[ -n $rp ]] && rpb=$'  restorePoint:\n'"    archive: \"$rp\""$'\n    index: 1'
  local tls=""
  if [[ $ENABLE_DB_TLS == true ]]; then
    tls=$'  httpsNMATLS:\n    enabled: true'; [[ -n $hsec ]] && tls+=$'\n'"    secret: $hsec"
    tls+=$'\n  clientServerTLS:\n    enabled: true'; [[ -n $csec ]] && tls+=$'\n'"    secret: $csec"
    if [[ $ENABLE_INTERNODE_TLS == true ]]; then
      # Vertica 26.3 docs "Enable TLS in Vertica on Kubernetes": internode TLS (26.1.0-0+), default mode VERIFY_CA
      tls+=$'\n  interNodeTLS:\n    enabled: true\n    mode: VERIFY_CA'; [[ -n $isec ]] && tls+=$'\n'"    secret: $isec"
    fi
  fi
  local npl=""; [[ $svctype == NodePort && -n $nodeport ]] && npl="    clientNodePort: $nodeport"
  local aff; aff=$(render_affinity "$name" required)
  cat <<EOF
# VerticaDB '$name' generated by $SCRIPT_NAME ($LAB_TAG)
apiVersion: vertica.com/v1
kind: VerticaDB
metadata:
  name: $name
  namespace: $NS
  labels:
    vertica-lab/managed: "true"
  annotations:
$ann
spec:
  image: $(state_get VERTICA_IMAGE_RESOLVED)
  imagePullPolicy: IfNotPresent
  dbName: $dbname
  initPolicy: $policy
$rpb
  passwordSecret: vdb-su-password
$lic
  autoRestartVertica: true
  upgradePolicy: Auto
  shardCount: $shards
  labels:
    vertica-lab/db: $name
  communal:
    path: "$cpath"
    endpoint: "$MINIO_ENDPOINT"
    credentialSecret: communal-creds
    region: us-east-1
  local:
    requestSize: 20Gi
    storageClass: standard
$tls
  subclusters:
  - name: primary
    type: primary
    size: $psize
    serviceType: $svctype
$npl
    resources:
      requests: {cpu: "$cpu", memory: ${mem}Gi}
      limits: {cpu: "$cpu", memory: ${mem}Gi}
    affinity:
$aff
EOF
}
apply_with_retry() { # file attempts
  local f=$1 n=${2:-18} i
  for (( i = 1; i <= n; i++ )); do
    if run --allow-fail kc apply -f "$f"; then return 0; fi
    warn "Apply attempt $i/$n failed (admission webhook may still be starting) — retrying in 10s"; sleep 10
  done
  return 1
}
vdb_pods_json() { { kc -n "$NS" get pods -o json 2>/dev/null || echo '{"items":[]}'; } | jq --arg p "$1-" '[.items[] | select(.metadata.name|startswith($p))]'; }
pods_ready_count() { # vdbname -> "ready total"
  vdb_pods_json "$1" | jq -r '"\([.[] | select(any(.status.conditions[]?; .type=="Ready" and .status=="True"))] | length) \(length)"'
}
# Operator watchdog: verticadb-operator 26.2.x can keep polling a pod IP that no longer exists
# (e.g. after a pod restart during NMA certificate rotation) and never progress. If its recent
# NMA errors target only IPs that belong to no current pod, restart the operator pod (at most
# once per 5 minutes). Observed on this lab; restarting the controller is safe (stateless).
WD_LAST_CHECK=0; WD_LAST_RESTART=0; WD_SUSPECT=0
operator_watchdog() {
  local now; now=$(date +%s)
  (( now - WD_LAST_CHECK >= 45 )) || return 0
  WD_LAST_CHECK=$now
  local op; op=$(kc -n "$OP_NS" get pods -o name 2>/dev/null | grep -i verticadb-operator | head -n1 || true)
  [[ -n $op ]] || return 0
  local hosts ips stale=""
  hosts=$(kc -n "$OP_NS" logs "$op" --since=60s 2>/dev/null | grep -E 'EXCEPTION|i/o timeout|connection refused' | grep -oE 'on host [0-9.]+' | awk '{print $3}' | sort -u || true)
  [[ -n $hosts ]] || { WD_SUSPECT=0; return 0; }
  ips=$(kc -n "$NS" get pods -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}' 2>/dev/null || true)
  local h; for h in $hosts; do grep -qxF "$h" <<<"$ips" || stale+="$h "; done
  if [[ -z $stale ]]; then WD_SUSPECT=0; return 0; fi
  WD_SUSPECT=$((WD_SUSPECT + 1))
  if (( WD_SUSPECT >= 2 && now - WD_LAST_RESTART >= 300 )); then
    printf '    %s%s operator watchdog%s operator keeps polling stale pod IP(s) %s(no such pod) — restarting the operator pod\n' "$C_YELLOW" "$U_K8S" "$C_RESET" "$stale"
    _log "WATCHDOG restarting operator: stale hosts $stale"
    kc -n "$OP_NS" delete "$op" --wait=false >/dev/null 2>&1 || true
    WD_LAST_RESTART=$now; WD_SUSPECT=0
  fi
  return 0
}
show_vdb_events() { # prints new operator events for VerticaDB objects (WAIT_HOOK)
  [[ -n ${WATCH_VDB:-} ]] || return 0
  operator_watchdog
  local lines l key
  lines=$(kc -n "$NS" get events --field-selector "involvedObject.name=$WATCH_VDB" -o json 2>/dev/null \
    | jq -r '.items | sort_by(.lastTimestamp // .eventTime // .metadata.creationTimestamp) | .[] | "\(.metadata.uid)|\(.type)|\(.reason)|\(.message | gsub("\n";" ") | .[0:140])"' 2>/dev/null) || return 0
  while IFS= read -r l; do
    [[ -z $l ]] && continue; key=${l%%|*}
    grep -qxF "$key" "$EVENTS_SEEN_FILE" 2>/dev/null && continue
    printf '%s\n' "$key" >>"$EVENTS_SEEN_FILE"
    IFS='|' read -r _ etype reason msg <<<"$l"
    local col=$C_CYAN; [[ $etype == Warning ]] && col=$C_YELLOW
    printf '    %s%s operator event%s %s%-28s%s %s\n' "$col" "$U_K8S" "$C_RESET" "$C_BOLD" "$reason" "$C_RESET" "$(_mask "$msg")"
    _log "EVENT $WATCH_VDB $etype $reason $msg"
  done <<<"$lines"
  return 0
}
# vsql over the local socket inside a Vertica pod (LOCAL auth: works regardless of the TLS policy)
vsql_local() { # pod db "SQL"
  printf '%s\n%s\n' "$DB_PASSWORD" "$3" | timeout 60 "${KC[@]}" exec -i -n "$NS" "$1" -c server -- \
    sh -c 'IFS= read -r VSQL_PASSWORD; export VSQL_PASSWORD; exec /opt/vertica/bin/vsql -X -q -At -v ON_ERROR_STOP=1 -d "$1" -U "$2"' sh "$2" "$DB_USER"
}
first_ready_pod() { vdb_pods_json "$1" | jq -r '[.[] | select(any(.status.conditions[]?; .type=="Ready" and .status=="True")) | .metadata.name] | sort | .[0] // empty'; }
# With clientServerTLS enabled, operator 26.2.x creates strict auth records for dbadmin:
#   k8s_*_reject_non_tls_builtin_auth (REJECT plain text)  +  k8s_*_tls_builtin_auth (TLS client certificate).
# The operator itself authenticates to the HTTPS service (8443) with its client certificate, so that
# record must stay the one selected. Password clients (vsql -m prefer) are supported the documented
# way: vertica.com/enable-fallthrough="true" => a TLS login without a certificate falls through to the
# password record. Plain-text remote logins remain REJECTED.
# If the CR is created WITH enable-fallthrough, the operator creates only the TLS records (no REJECT
# records); ensure_db_access then adds vlab_reject_plain_ipv4/ipv6 (HOST NO TLS -> reject).
# NOTE: never add a higher-priority password record for PUBLIC: it hides the certificate record, the
# operator's HTTPS calls fail with "Wrong certificate" and it can no longer restart nodes.
ensure_db_access() { # vdbname dbname
  [[ $ENABLE_DB_TLS == true ]] || return 0
  local pod; pod=$(first_ready_pod "$1" || true); [[ -n $pod ]] || return 0
  if [[ $(kc -n "$NS" get vdb "$1" -o jsonpath='{.metadata.annotations.vertica\.com/enable-fallthrough}' 2>/dev/null || true) != true ]]; then
    kc -n "$NS" annotate vdb "$1" vertica.com/enable-fallthrough=true --overwrite >/dev/null 2>&1 || true
  fi
  local legacy todo a sql=""
  legacy=$(vsql_local "$pod" "$2" "SELECT COUNT(*) FROM client_auth WHERE auth_name='vlab_tls_password';" 2>/dev/null | tr -d '[:space:]' || true)
  if [[ $legacy == 1 ]]; then
    vsql_local "$pod" "$2" "DROP AUTHENTICATION vlab_tls_password CASCADE;" >>"${LOG_FILE:-/dev/null}" 2>&1 || true
    ok "Removed legacy auth record vlab_tls_password (it hid the operator's TLS certificate auth and blocked node restarts)"
  fi
  todo=$(vsql_local "$pod" "$2" "SELECT auth_name FROM client_auth WHERE auth_name LIKE 'k8s%tls_builtin_auth' AND auth_method='TLS' AND is_fallthrough_enabled::VARCHAR NOT IN ('True','true','t') ORDER BY 1;" 2>/dev/null || true)
  if [[ -n $todo ]]; then
    for a in $todo; do sql+="ALTER AUTHENTICATION $a FALLTHROUGH; "; done
    if vsql_local "$pod" "$2" "$sql" >>"${LOG_FILE:-/dev/null}" 2>&1; then
      ok "Auth policy for $2: TLS certificate first, then password over TLS (fallthrough)"
    else warn "Could not enable TLS->password fallthrough in $2 (remote password logins may fail)"; fi
  fi
  # Plain-text remote logins must be rejected. When the CR is created with enable-fallthrough the operator does
  # not create its own REJECT records, so the lab adds them. HOST NO TLS records match only non-TLS connections,
  # so they never hide the operator's TLS-certificate records (operator HTTPS / node restarts keep working).
  local rej; rej=$(vsql_local "$pod" "$2" "SELECT COUNT(*) FROM client_auth WHERE auth_method='REJECT' AND auth_host_type='HOSTNOSSL' AND is_auth_enabled::VARCHAR IN ('True','true','t');" 2>/dev/null | tr -d '[:space:]' || true)
  if [[ $rej == 0 ]]; then
    if vsql_local "$pod" "$2" "CREATE AUTHENTICATION vlab_reject_plain_ipv4 METHOD 'reject' HOST NO TLS '0.0.0.0/0';
CREATE AUTHENTICATION vlab_reject_plain_ipv6 METHOD 'reject' HOST NO TLS '::/0';
ALTER AUTHENTICATION vlab_reject_plain_ipv4 PRIORITY 10; ALTER AUTHENTICATION vlab_reject_plain_ipv6 PRIORITY 10;
GRANT AUTHENTICATION vlab_reject_plain_ipv4 TO PUBLIC; GRANT AUTHENTICATION vlab_reject_plain_ipv6 TO PUBLIC;" >>"${LOG_FILE:-/dev/null}" 2>&1; then
      ok "Auth policy for $2: plain-text (non-TLS) remote logins are REJECTED (records vlab_reject_plain_ipv4/ipv6)"
    else warn "Could not create the plain-text REJECT auth records in $2 (non-TLS remote logins stay possible)"; fi
  fi
  return 0
}
db_ready_probe() { # vdbname dbname expected_nodes
  local name=$1 db=$2 n=$3 ready total up pod
  read -r ready total < <(pods_ready_count "$name")
  pod=$(first_ready_pod "$name" || true)
  up=""; [[ -n $pod ]] && up=$(vsql_local "$pod" "$db" "SELECT COUNT(*) FROM nodes WHERE node_state='UP';" 2>/dev/null | tr -d '[:space:]' || true)
  [[ $up =~ ^[0-9]+$ ]] || up="-"
  printf 'pods Ready %s/%s | Vertica nodes UP %s/%s' "${ready:-0}" "$n" "$up" "$n"
  [[ ${ready:-0} -ge $n && $up != "-" && $up -ge $n ]]
}
wait_db_ready() { # vdbname dbname nodes timeout desc
  WATCH_VDB=$1; WAIT_HOOK=show_vdb_events
  local rc=0
  wait_until "${5:-Database $2 ready}" "$4" 10 db_ready_probe "$1" "$2" "$3" || rc=$?
  WAIT_HOOK=""; WATCH_VDB=""
  if (( rc == 0 )); then ensure_db_access "$1" "$2"; fi
  return $rc
}
client_probe() {
  local s; s=$(kc -n "$NS" get pod "$CLIENT_POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  printf 'client pod: %s' "${s:-absent}"
  [[ $s == Running ]] && kc -n "$NS" exec "$CLIENT_POD" -c client -- true >/dev/null 2>&1
}
deploy_client() {
  cat >"$MANIFEST_DIR/client.yaml" <<EOF
# vsql client used by the automation (same official image => same vsql version)
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: vlab-client, namespace: $NS, labels: {app: vlab-client}}
spec:
  serviceName: vlab-client
  replicas: 1
  selector: {matchLabels: {app: vlab-client}}
  template:
    metadata: {labels: {app: vlab-client, vertica-client: "true"}}
    spec:
      serviceAccountName: vlab-client
      nodeSelector: {node-role.kubernetes.io/control-plane: ""}
      tolerations:
      - {key: node-role.kubernetes.io/control-plane, operator: Exists, effect: NoSchedule}
      securityContext: {runAsUser: 5000, runAsGroup: 5000, runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}
      containers:
      - name: client
        image: $(state_get VERTICA_IMAGE_RESOLVED)
        imagePullPolicy: IfNotPresent
        command: ["sleep", "infinity"]
        env:
        - {name: HOME, value: /tmp}
        resources:
          requests: {cpu: 200m, memory: 256Mi}
          limits: {cpu: "2", memory: 1536Mi}
        securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
EOF
  run kc apply -f "$MANIFEST_DIR/client.yaml"
  wait_until "SQL client pod ready" 600 5 client_probe
}
plan_resources() {
  local avail_gb total_gb cpus budget mem cpu emem ecpu rows
  total_gb=$(( $(mem_kb MemTotal) / 1048576 )); avail_gb=$(( $(mem_kb MemAvailable) / 1048576 )); cpus=$(nproc)
  budget=$(( avail_gb - HOST_RESERVE_GB - 5 ))
  if [[ -n $(state_get VDB_MEM_GB) && -z $VDB_MEMORY_GB ]]; then mem=$(state_get VDB_MEM_GB)
  elif [[ -n $VDB_MEMORY_GB ]]; then mem=$VDB_MEMORY_GB
  else mem=$(( budget * 2 / 11 )); (( mem > 8 )) && mem=8; (( mem < 2 )) && mem=2; fi
  (( budget >= 3 * mem )) || die "Insufficient free RAM: budget ${budget} GB < 3 x ${mem} GB. Free memory or set VDB_MEMORY_GB/HOST_RESERVE_GB."
  if [[ -n $(state_get VDB_CPU_CORES) && -z $VDB_CPU ]]; then cpu=$(state_get VDB_CPU_CORES)
  elif [[ -n $VDB_CPU ]]; then cpu=$VDB_CPU
  else cpu=$(( (cpus - 2) * 2 / 11 )); (( cpu > 4 )) && cpu=4; (( cpu < 1 )) && cpu=1; fi
  emem=$(( mem / 2 )); (( emem < 2 )) && emem=2; (( emem > 4 )) && emem=4
  ecpu=$(( cpu / 2 )); (( ecpu < 1 )) && ecpu=1
  if [[ -n $SALES_ROWS ]]; then rows=$SALES_ROWS
  elif (( mem >= 6 )); then rows=5000000; elif (( mem >= 4 )); then rows=2000000; else rows=1000000; fi
  local maxn=$VERTICA_MAX_NODES
  [[ -z $maxn ]] && { [[ -n $(state_get LICENSE_INSTALLED) ]] && maxn=5 || maxn=3; }
  state_set VDB_MEM_GB "$mem"; state_set VDB_CPU_CORES "$cpu"; state_set ELASTIC_MEM_GB "$emem"
  state_set ELASTIC_CPU_CORES "$ecpu"; state_set SALES_ROWS "$rows"; state_set MAX_NODES "$maxn"
  info "Resource plan (resource-aware sizing; kind nodes all share this workstation's RAM/CPU):"
  kv "Host RAM total / available" "${total_gb} GB / ${avail_gb} GB"
  kv "Reserved for host + host Vertica" "${HOST_RESERVE_GB} GB (HOST_RESERVE_GB)"
  kv "Per Vertica pod (Guaranteed QoS)" "${mem} GiB RAM, ${cpu} CPU (requests = limits)"
  kv "HA database footprint" "3 pods = $(( 3 * mem )) GiB"
  kv "Scaling-test pods (temporary)" "up to 2 x ${emem} GiB RAM, ${ecpu} CPU"
  kv "Licensed max nodes / scaling path" "$maxn / $([[ $maxn -ge 5 ]] && echo 'secondary subcluster on main DB' || echo 'separate 1+2 node elastic DB (trial limit 3)')"
  kv "Fact table rows (SALES_ROWS)" "$rows"
}
setup_db_secrets() {
  local pf="$TMPDIR_LAB/pw.env"
  printf 'password=%s\n' "$DB_PASSWORD" >"$pf"; apply_secret_env "$NS" vdb-su-password "$pf"; rm -f "$pf"
  ok "Kubernetes Secret $NS/vdb-su-password (superuser password; never stored in the CR)"
  local lic=$VERTICA_LICENSE_FILE
  [[ -z $lic && -f $LAB_DIR/vertica_license.dat ]] && lic="$LAB_DIR/vertica_license.dat"
  if [[ -n $lic ]]; then
    [[ -r $lic ]] || die "License file not readable: $lic"
    local norm="$TMPDIR_LAB/license.dat"; tr -d '\r' <"$lic" >"$norm"     # normalise CRLF line endings
    kc create secret generic vdb-license -n "$NS" --from-file=license.dat="$norm" --dry-run=client -o yaml | kc apply -f - >/dev/null
    rm -f "$norm"; state_set LICENSE_INSTALLED 1; state_set LICENSE_SOURCE "$lic"
    ok "License Secret $NS/vdb-license created from $lic (CRLF normalised; the file itself is never modified or deleted)"
  else
    info "No license file supplied (--license FILE or $LAB_DIR/vertica_license.dat) — using image default (trial: <=3 nodes)."
  fi
}
deploy_vdb() {
  step "Eon Mode VerticaDB '$DB_NAME' (CR '$VDB': 3-node K-safe primary subcluster)"
  what "Create Secrets, the vsql client pod and the VerticaDB custom resource; the operator builds the DB."
  why  "Exercises the operator's full create workflow: StatefulSet, PVCs, services, create_db, TLS, license."
  setup_db_secrets
  plan_resources
  deploy_client
  local install_id; install_id=$(state_get INSTALL_ID); [[ -z $install_id ]] && { install_id=$(date +%Y%m%d%H%M%S); state_set INSTALL_ID "$install_id"; }
  local cpath="s3://$BUCKET/$DB_NAME-$install_id"; state_set COMMUNAL_PATH "$cpath"
  if kc -n "$NS" get vdb "$VDB" >/dev/null 2>&1; then
    ok "VerticaDB '$VDB' already exists — the operator keeps reconciling it (idempotent)"
  else
    local policy=$DB_INIT_POLICY
    if [[ $(state_get DB_CREATED) == 1 ]]; then policy=Revive; warn "DB was created before but CR is missing — REVIVING from $cpath"; fi
    render_vdb "$VDB" "$DB_NAME" "$cpath" "$policy" 3 "$(state_get VDB_MEM_GB)" "$(state_get VDB_CPU_CORES)" NodePort "$NODEPORT_PRIMARY" false 6 \
      >"$MANIFEST_DIR/vdb.yaml"
    info "VerticaDB manifest: $MANIFEST_DIR/vdb.yaml"
    sed -n '1,200p' "$MANIFEST_DIR/vdb.yaml" | grep -vE '^\s*$' | head -n 60 | while IFS= read -r l; do printf '      %s%s%s\n' "$C_DIM" "$l" "$C_RESET"; done
    apply_with_retry "$MANIFEST_DIR/vdb.yaml" || die "Could not create VerticaDB CR"
  fi
  info "The operator now creates StatefulSet/PVCs/Services and bootstraps the database. Live operator events:"
  wait_db_ready "$VDB" "$DB_NAME" 3 "$DB_CREATE_TIMEOUT" "Vertica database $DB_NAME up (3/3 nodes)" \
    || { run --show --allow-fail kc -n "$NS" describe vdb "$VDB"; die "Database did not become ready. If the license is the issue, supply --license FILE."; }
  state_set DB_CREATED 1
  run --show kc -n "$NS" get vdb,sts,pods,pvc,svc -o wide
  step_done
}
#==============================================================================
# Identity provider (Keycloak) + OAuth 2.0 / JWT machine-to-machine database login
#==============================================================================
# Vertica 26.3 docs, "OAuth 2.0 authentication": an 'oauth' authentication record with validate_type='JWT'
# verifies the token signature with the identity provider's keys (jwt_jwks_url), plus issuer, audience,
# scope and expiry. Keycloak is one of the identity providers Vertica tests officially.
# The ETL "service" has no password: it proves itself to Keycloak with its client credentials
# (grant_type=client_credentials) and presents the signed token (a JWT) to Vertica.
keycloak_probe() {
  local r; r=$(kc -n "$IDP_NS" get deploy keycloak -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
  printf 'Keycloak ready replicas: %s/1' "${r:-0}"; [[ ${r:-0} -ge 1 ]]
}
# kcadm VARS < snippet : runs a bash snippet inside the Keycloak pod with an admin session.
# The admin credentials come from the pod's own environment (Kubernetes Secret); VARS are bash
# assignments (printf %q) so client secrets travel on stdin only — never on a command line or in a log.
kcadm() {
  { cat <<'PRE'
set -e; export HOME=/tmp; A=/opt/keycloak/bin/kcadm.sh
$A config credentials --server http://localhost:8080 --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null 2>&1
byname(){ while IFS=, read -r i n; do if [ "$n" = "$1" ]; then echo "$i"; fi; done; true; }
PRE
    printf '%s\n' "${1:-}"; cat; } | kc -n "$IDP_NS" exec -i deploy/keycloak -- bash -s
}
configure_keycloak() {
  local vars
  vars=$(printf 'R=%q; SEC_svc_etl=%q; SEC_svc_other=%q; SEC_svc_short=%q' "$IDP_REALM" \
    "$OAUTH_SECRET_svc_etl" "$OAUTH_SECRET_svc_other" "$OAUTH_SECRET_svc_short")
  kcadm "$vars" <<'KC' 2>&1 | while IFS= read -r l; do _log "      keycloak: $l"; done
$A get "realms/$R" >/dev/null 2>&1 || { $A create realms -s realm="$R" -s enabled=true -s accessTokenLifespan=300; echo "realm $R created"; }
# client scope 'vertica': adds the audience "vertica" and the scope "vertica" to the token
SID=$($A get client-scopes -r "$R" --fields id,name --format csv --noquotes | byname vertica)
if [ -z "$SID" ]; then
  SID=$($A create client-scopes -r "$R" -s name=vertica -s protocol=openid-connect -s 'attributes."include.in.token.scope"=true' -i)
  $A create "client-scopes/$SID/protocol-mappers/models" -r "$R" -s name=vertica-audience -s protocol=openid-connect \
     -s protocolMapper=oidc-audience-mapper -s 'config."included.custom.audience"=vertica' -s 'config."access.token.claim"=true' -s 'config."id.token.claim"=false' >/dev/null
  echo "client scope vertica created"
fi
mk() { # clientId attach-vertica-scope(yes|no) token-lifespan-seconds(optional)
  local sec_var="SEC_$1" CID; CID=$($A get clients -r "$R" --fields id,clientId --format csv --noquotes | byname "$1")
  if [ -z "$CID" ]; then
    CID=$($A create clients -r "$R" -s clientId="$1" -s enabled=true -s publicClient=false -s serviceAccountsEnabled=true \
          -s standardFlowEnabled=false -s directAccessGrantsEnabled=false -s clientAuthenticatorType=client-secret -s secret="${!sec_var}" -i)
    echo "client $1 created"
  else $A update "clients/$CID" -r "$R" -s secret="${!sec_var}"; fi
  # least privilege: the token carries exactly one audience ("vertica") and only the claims a service needs
  for kind in default-client-scopes optional-client-scopes; do
    $A get "clients/$CID/$kind" -r "$R" --fields id,name --format csv --noquotes | while IFS=, read -r sid sname; do
      case $sname in basic|service_account|vertica) ;; *) $A delete "clients/$CID/$kind/$sid" -r "$R" ;; esac
    done
  done
  if [ "$2" = yes ]; then $A update "clients/$CID/default-client-scopes/$SID" -r "$R"; fi
  if [ -n "${3:-}" ]; then $A update "clients/$CID" -r "$R" -s "attributes.\"access.token.lifespan\"=$3"; fi
  echo "client $1 ready (service account, client_credentials grant)"
}
mk svc_etl yes          # the ETL service
mk svc_other no         # negative test: token without the "vertica" audience
mk svc_short yes 15     # negative test: token that expires after 15 s
KC
  return "${PIPESTATUS[0]}"
}
deploy_keycloak() {
  step "Identity provider: Keycloak (OAuth 2.0 / OpenID Connect) for machine-to-machine logins"
  what "Run Keycloak in namespace $IDP_NS, create realm '$IDP_REALM' and service clients that log in with client credentials."
  why  "Applications and jobs should not hold database passwords: they get a short-lived signed token (JWT) instead."
  cat >"$MANIFEST_DIR/keycloak-ns.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $IDP_NS
  labels:
    vertica-lab/managed: "true"
    pod-security.kubernetes.io/warn: restricted
EOF
  run kc apply -f "$MANIFEST_DIR/keycloak-ns.yaml"
  local envf="$TMPDIR_LAB/kc.env"
  printf 'username=admin\npassword=%s\n' "$KEYCLOAK_ADMIN_PASSWORD" >"$envf"; apply_secret_env "$IDP_NS" keycloak-admin "$envf"; rm -f "$envf"
  ok "Kubernetes Secret $IDP_NS/keycloak-admin (Keycloak bootstrap admin)"
  cat >"$MANIFEST_DIR/keycloak.yaml" <<EOF
# Keycloak for $LAB_TAG — lab mode (start-dev: in-memory dev database, HTTP inside the cluster only).
# Production: 'start' with TLS, an external database and 2+ replicas (or your corporate IdP, e.g. Okta / OTDS).
apiVersion: apps/v1
kind: Deployment
metadata: {name: keycloak, namespace: $IDP_NS, labels: {app: keycloak}}
spec:
  replicas: 1
  selector: {matchLabels: {app: keycloak}}
  template:
    metadata: {labels: {app: keycloak}}
    spec:
      nodeSelector: {node-role.kubernetes.io/control-plane: ""}
      tolerations:
      - {key: node-role.kubernetes.io/control-plane, operator: Exists, effect: NoSchedule}
      securityContext: {runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}
      containers:
      - name: keycloak
        image: $KEYCLOAK_IMAGE
        imagePullPolicy: IfNotPresent
        args: ["start-dev", "--http-port=8080", "--health-enabled=true", "--hostname=$IDP_URL"]
        env:
        - {name: KC_BOOTSTRAP_ADMIN_USERNAME, valueFrom: {secretKeyRef: {name: keycloak-admin, key: username}}}
        - {name: KC_BOOTSTRAP_ADMIN_PASSWORD, valueFrom: {secretKeyRef: {name: keycloak-admin, key: password}}}
        ports:
        - {containerPort: 8080, name: http}
        - {containerPort: 9000, name: management}
        readinessProbe:
          httpGet: {path: /health/ready, port: 9000}
          periodSeconds: 5
          failureThreshold: 60
        resources:
          requests: {cpu: 500m, memory: 768Mi}
          limits: {cpu: "2", memory: 1536Mi}
        securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
---
apiVersion: v1
kind: Service
metadata: {name: keycloak, namespace: $IDP_NS}
spec:
  selector: {app: keycloak}
  ports:
  - {name: http, port: 8080, targetPort: 8080}
EOF
  run kc apply -f "$MANIFEST_DIR/keycloak.yaml"
  wait_until "Keycloak ready" 600 5 keycloak_probe || die "Keycloak did not become ready (see: kubectl -n $IDP_NS logs deploy/keycloak)"
  configure_keycloak || die "Keycloak realm configuration failed (details in the log)"
  ok "Realm '$IDP_REALM': client scope 'vertica' (audience + scope) and service clients ${OAUTH_CLIENTS[*]}"
  local cf="$TMPDIR_LAB/oauth.env" c v
  : >"$cf"; for c in "${OAUTH_CLIENTS[@]}"; do v="OAUTH_SECRET_$c"; printf '%s=%s\n' "$c" "${!v}" >>"$cf"; done
  apply_secret_env "$NS" oauth-clients "$cf"; rm -f "$cf"
  ok "Kubernetes Secret $NS/oauth-clients (client secrets for the service workloads)"
  local disc; disc=$(kc -n "$NS" exec "$CLIENT_POD" -c client -- curl -fsS --max-time 20 "$IDP_ISSUER/.well-known/openid-configuration" 2>/dev/null | jq -r '.issuer // empty' || true)
  [[ $disc == "$IDP_ISSUER" ]] && ok "OpenID Connect discovery from the Vertica namespace: issuer $disc" || warn "OIDC discovery check failed (issuer '${disc:-n/a}')"
  configure_oauth_db || die "Could not create the OAuth/JWT authentication record in $DB_NAME"
  state_set OAUTH_INSTALLED 1
  step_done
}
# Vertica side: one 'oauth' record with JWT validation, TLS connections only, granted to the service users only
# (never to PUBLIC or dbadmin, so it cannot hide the operator's TLS-certificate login).
configure_oauth_db() {
  local pod; pod=$(first_ready_pod "$VDB" || true); [[ -n $pod ]] || return 1
  local u grants="" sql have
  have=$(vsql_local "$pod" "$DB_NAME" "SELECT user_name FROM users WHERE user_name IN ('$(IFS=,; echo "${OAUTH_CLIENTS[*]}" | sed "s/,/','/g")');" 2>/dev/null || true)
  for u in "${OAUTH_CLIENTS[@]}"; do
    grep -qx "$u" <<<"$have" || grants+="CREATE USER $u; "     # no password: these accounts can only log in with a token
    grants+="GRANT AUTHENTICATION $OAUTH_RECORD TO $u; "
  done
  sql="DROP AUTHENTICATION IF EXISTS $OAUTH_RECORD CASCADE;
CREATE AUTHENTICATION $OAUTH_RECORD METHOD 'oauth' HOST TLS '0.0.0.0/0';
ALTER AUTHENTICATION $OAUTH_RECORD SET validate_type='JWT', jwt_issuer='$IDP_ISSUER', jwt_user_mapping='azp',
  jwt_jwks_url='$IDP_ISSUER/protocol/openid-connect/certs', jwt_accepted_audience_list='vertica', jwt_accepted_scope_list='vertica';
$grants"
  vsql_local "$pod" "$DB_NAME" "$sql" >>"${LOG_FILE:-/dev/null}" 2>&1 || return 1
  ok "Vertica auth record $OAUTH_RECORD: METHOD oauth, validate_type=JWT, keys from JWKS, issuer + audience + scope enforced, TLS only"
  vsql_show "${VDB}-primary" "$DB_NAME" "OAuth / JWT authentication record" \
    "SELECT auth_name, auth_method, auth_host_type, is_auth_enabled, REPLACE(auth_parameters, '$IDP_URL', '<keycloak>') AS parameters FROM client_auth WHERE auth_name='$OAUTH_RECORD';" || true
  return 0
}
# ---- helpers used by --test and --demo (tokens are bearer credentials: never printed or logged) ----
oauth_token() { # client -> access token on stdout (client_credentials grant, requested from inside the cluster)
  local v="OAUTH_SECRET_$1"
  printf '%s\n' "${!v}" | kc -n "$NS" exec -i "$CLIENT_POD" -c client -- sh -c \
    'IFS= read -r S; curl -s --max-time 20 -u "$1:$S" -d grant_type=client_credentials "$2/protocol/openid-connect/token"' sh "$1" "$IDP_ISSUER" 2>/dev/null \
    | jq -r '.access_token // empty' 2>/dev/null || true
}
jwt_part() { # token index(0=header,1=payload) -> decoded JSON
  local s; s=$(cut -d. -f"$(( $2 + 1 ))" <<<"$1" | tr '_-' '/+')
  while (( ${#s} % 4 )); do s+="="; done
  base64 -d <<<"$s" 2>/dev/null || true
}
# vsql login with a token. The database user is ALWAYS passed with -U: the session identity is still taken
# from the signed token (verified in T07), and an OAuth start-up request without a user name is avoided.
oauth_login() { # token user "SQL" [host]
  printf '%s\n' "$1" | kc -n "$NS" exec -i "$CLIENT_POD" -c client -- sh -c \
    'unset VSQL_PASSWORD; IFS= read -r VSQL_OAUTH_ACCESS_TOKEN; export VSQL_OAUTH_ACCESS_TOKEN
     exec vsql -X -At -m require -h "$1" -d "$2" -M oauth -U "$3" -c "$4" </dev/null' sh "${4:-${VDB}-primary}" "$DB_NAME" "$2" "$3" 2>&1
}
post_install_summary() {
  step "Post-install verification and connection details"
  what "Run quick SQL against the new database and print how to connect."
  vsql_show "${VDB}-primary" "$DB_NAME" "Cluster nodes" "SELECT n.node_name, n.node_state, n.node_address, s.subcluster_name, s.is_primary FROM nodes n JOIN subclusters s ON s.node_name = n.node_name ORDER BY 1;" || true
  vsql_show "${VDB}-primary" "$DB_NAME" "Version / fault tolerance" "SELECT version() AS version, (SELECT designed_fault_tolerance FROM system) AS designed_k, (SELECT current_fault_tolerance FROM system) AS current_k;" || true
  state_set INSTALL_COMPLETE 1; state_set INSTALL_TIME "$(date '+%F %T')"
  info "Connect from this workstation (host vsql, read-only use of /opt/vertica/bin/vsql):"
  detail "/opt/vertica/bin/vsql -m prefer -h 127.0.0.1 -p $HOST_PORT_PRIMARY -U $DB_USER -d $DB_NAME"
  detail "password: sudo grep DB_PASSWORD $SECRETS_FILE | cut -d= -f2"
  info "kubectl for the lab: sudo $BIN_DIR/kubectl --kubeconfig $KUBECONFIG_FILE get pods -n $NS"
  step_done
}

#==============================================================================
# --install
#==============================================================================
do_install() {
  banner "VERTICA KUBERNETES OPERATOR $VERTICA_TARGET_VERSION LAB — INSTALL" "kind + MinIO + verticadb-operator + Eon VerticaDB + Keycloak | $(date '+%F %T') | log: $LOG_FILE"
  STEP_TOTAL=12; [[ $ENABLE_OAUTH == true ]] && STEP_TOTAL=13
  state_set TARGET_VERSION "$VERTICA_TARGET_VERSION"
  preflight
  ensure_prereqs
  ensure_secrets
  tune_kernel
  install_tools
  resolve_images
  create_cluster
  load_images
  install_addons
  deploy_minio
  install_operator
  deploy_vdb
  if [[ $ENABLE_OAUTH == true ]]; then deploy_keycloak; fi
  post_install_summary
  banner "INSTALL COMPLETE" "Next:  sudo $SCRIPT_PATH --test     (or --status)"
}

#==============================================================================
# Test framework
#==============================================================================
RESULTS_CSV=""; PERF_CSV=""; T_ID=""; T_RES=""; T_NUM=0; T_TOTAL=0; TEST_EXIT=0
declare -a T_ORDER=() T_STATUSES=()
group_selected() {
  local g=$1
  if [[ -n $ONLY_GROUPS ]] && [[ ",$ONLY_GROUPS," != *",$g,"* ]]; then return 1; fi
  if [[ -n $SKIP_GROUPS ]] && [[ ",$SKIP_GROUPS," == *",$g,"* ]]; then return 1; fi
  return 0
}
t_pass() { printf 'PASS|%s\n' "$*" >>"$T_RES"; printf '    %s%s PASS%s %s\n' "$C_GREEN$C_BOLD" "$U_OK" "$C_RESET" "$(_mask "$*")"; _log "PASS  $*"; }
t_fail() { printf 'FAIL|%s\n' "$*" >>"$T_RES"; printf '    %s%s FAIL%s %s\n' "$C_RED$C_BOLD" "$U_FAIL" "$C_RESET" "$(_mask "$*")"; _log "FAIL  $*"; }
t_warn() { printf 'WARN|%s\n' "$*" >>"$T_RES"; printf '    %s%s WARN%s %s\n' "$C_YELLOW$C_BOLD" "$U_WARN" "$C_RESET" "$(_mask "$*")"; _log "WARN  $*"; }
t_skip() { printf 'SKIP|%s\n' "$*" >>"$T_RES"; printf '    %s- SKIP%s %s\n' "$C_DIM$C_BOLD" "$C_RESET" "$*"; _log "SKIP  $*"; }
t_info() { printf '    %s%s%s %s\n' "$C_BLUE" "$U_INFO" "$C_RESET" "$(_mask "$*")"; _log "INFO  $*"; }
t_check() { # "description" cmd...  -> PASS/FAIL based on exit code
  local d=$1; shift
  if "$@" >>"$LOG_FILE" 2>&1; then t_pass "$d"; else t_fail "$d"; fi
}
metric() { # name value [unit] [note]
  local name=$1 val=${2:-n/a} unit=${3:-} note=${4:-}
  printf '%s,%s,%s,%s,"%s"\n' "$T_ID" "$name" "$val" "$unit" "$note" >>"$PERF_CSV"
  printf '    %s%s METRIC%s %-42s %s%s %s%s %s\n' "$C_CYAN" "$U_MET" "$C_RESET" "$name" "$C_BOLD" "$val" "$unit" "$C_RESET" "${note:+${C_DIM}($note)${C_RESET}}"
  _log "METRIC $name=$val $unit $note"
}
_t_err() { printf 'FAIL|unexpected error at line %s: %s\n' "$1" "$2" >>"$T_RES"; printf '    %s%s error at line %s:%s %s\n' "$C_RED" "$U_FAIL" "$1" "$C_RESET" "$(_mask "$2")"; }
scope_label() {
  case $1 in
    REAL) printf '%sLOCAL-REAL%s' "$C_GREEN" "$C_RESET" ;;
    SIM)  printf '%sLOCAL-SIMULATED%s' "$C_YELLOW" "$C_RESET" ;;
    PROD) printf '%sPROD-CLUSTER-ONLY%s' "$C_MAGENTA" "$C_RESET" ;;
  esac
}
status_bg() {
  [[ -n $C_RESET ]] || return 0
  case $1 in PASS) printf '%s' "$C_BGGREEN";; FAIL) printf '%s' "$C_BGRED";; WARN) printf '%s' $'\e[43m';; *) printf '%s' $'\e[100m';; esac
}
fmt_dur() { local d=${1:-0}; if (( d >= 60 )); then printf '%dm%02ds' $(( d / 60 )) $(( d % 60 )); else printf '%ds' "$d"; fi; }
scope_text() {
  case $1 in
    REAL) printf 'LOCAL-REAL — the real Vertica/Kubernetes mechanism runs exactly as in production' ;;
    SIM)  printf 'LOCAL-SIMULATED — real recovery mechanism; the failure itself is simulated (nodes are containers on one workstation)' ;;
    *)    printf '%s' "$1" ;;
  esac
}
# progress strip: one block per planned test, coloured by result (pending = dim)
test_progress_strip() {
  local i out="" st
  for (( i = 0; i < T_TOTAL; i++ )); do
    if (( i < ${#T_STATUSES[@]} )); then
      st=${T_STATUSES[$i]}
      case $st in PASS) out+="$C_GREEN$U_BAR_OK";; FAIL) out+="$C_RED$U_BAR_OK";; WARN) out+="$C_YELLOW$U_BAR_OK";; *) out+="$C_DIM$U_BAR_OK";; esac
    elif (( i == ${#T_STATUSES[@]} )); then out+="$C_BOLD$C_CYAN$U_BAR_OK"
    else out+="$C_DIM$U_BAR_FAIL"; fi
    out+="$C_RESET"
  done
  local p f w; p=$(printf '%s\n' ${T_STATUSES[@]+"${T_STATUSES[@]}"} | grep -c '^PASS$' || true)
  f=$(printf '%s\n' ${T_STATUSES[@]+"${T_STATUSES[@]}"} | grep -c '^FAIL$' || true)
  w=$(printf '%s\n' ${T_STATUSES[@]+"${T_STATUSES[@]}"} | grep -c '^WARN$' || true)
  printf '  %sProgress%s %s  %s%d done%s: %s%d PASS%s  %s%d FAIL%s  %s%d WARN%s   %s(cyan = running now)%s\n' "$C_DIM" "$C_RESET" "$out" \
    "$C_BOLD" "${#T_STATUSES[@]}" "$C_RESET" "$C_GREEN" "$p" "$C_RESET" "$C_RED" "$f" "$C_RESET" "$C_YELLOW" "$w" "$C_RESET" "$C_DIM" "$C_RESET"
}
# print one card line:  ┃ LABEL   text (wrapped, continuation aligned)
_card_line() { # colour label text
  local col=$1 label=$2 text=$3 width first=1 l
  width=$(( (TERM_COLS > 110 ? 110 : TERM_COLS) - 16 )); (( width < 50 )) && width=50
  while IFS= read -r l; do
    if (( first )); then printf '  %s%s%s %s%-8s%s %s\n' "$C_BLUE" "$U_CARD" "$C_RESET" "$C_BOLD$col" "$label" "$C_RESET" "$l"; first=0
    else printf '  %s%s%s %-8s   %s\n' "$C_BLUE" "$U_CARD" "$C_RESET" "" "$l"; fi
  done < <(printf '%s\n' "$text" | fold -s -w "$width")
}
# coloured dot: green = all up, yellow = partly, red = none / unknown
_sdot() { # have want
  local h=$1 w=$2 c=$C_RED
  [[ $h =~ ^[0-9]+$ ]] || h=0
  if (( w > 0 && h >= w )); then c=$C_GREEN; elif (( h > 0 )); then c=$C_YELLOW; fi
  printf '%s%s%s' "$c" "$U_DOT" "$C_RESET"
}
# STATUS line shown in every test card, measured just before the test starts
card_status_line() {
  local kr=0 kt=0 pr=0 pt=0 up=- nt=- pod="" db dbc line plain
  kr=$(kc get nodes -o json 2>/dev/null | jq '[.items[] | select(any(.status.conditions[]; .type=="Ready" and .status=="True"))] | length' 2>/dev/null || echo 0)
  kt=$(kc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  local term=0 tnote=""   # pods being deleted (e.g. scaled-in analytics pods) are shown separately
  read -r pr pt term < <(vdb_pods_json "$VDB" 2>/dev/null | jq -r '[.[] | select(.metadata.deletionTimestamp == null)] as $live
    | "\([$live[] | select(any(.status.conditions[]?; .type=="Ready" and .status=="True"))] | length) \($live | length) \(length - ($live | length))"' 2>/dev/null || echo "0 0 0") || true
  [[ $term =~ ^[0-9]+$ ]] && (( term > 0 )) && tnote=" ${C_DIM}(+${term} terminating)${C_RESET}"
  pod=$(first_ready_pod "$VDB" 2>/dev/null || true); up="-"; nt="-"
  if [[ -n $pod ]]; then
    read -r up nt < <(vsql_local "$pod" "$DB_NAME" "SELECT SUM(CASE WHEN node_state='UP' THEN 1 ELSE 0 END)||' '||COUNT(*) FROM nodes;" 2>/dev/null || echo "- -") || true
  fi
  [[ $up =~ ^[0-9]+$ ]] || up="-"; [[ $nt =~ ^[0-9]+$ ]] || nt="-"
  if [[ $up != - && $nt != - && $up -ge $nt && $nt -gt 0 ]]; then db="UP"; dbc=$C_GREEN
  elif [[ $up != - && $up -gt 0 ]]; then db="UP (degraded)"; dbc=$C_YELLOW
  else db="DOWN / unreachable"; dbc=$C_RED; fi
  line="$(_sdot "$kr" "$kt") K8s nodes ${kr}/${kt} Ready   $(_sdot "$pr" "$pt") Vertica pods ${pr}/${pt} Ready${tnote}   "
  line+="$(_sdot "${up/-/0}" "${nt/-/0}") Vertica nodes ${up}/${nt} UP   ${dbc}${U_DOT} Database $DB_NAME ${C_BOLD}${db}${C_RESET}"
  printf '  %s%s%s %s%-8s%s %s\n' "$C_BLUE" "$U_CARD" "$C_RESET" "$C_BOLD$C_WHITE" "STATUS" "$C_RESET" "$line"
  plain="K8s nodes ${kr}/${kt} Ready | Vertica pods ${pr}/${pt} Ready | Vertica nodes ${up}/${nt} UP | Database $DB_NAME $db"
  _log "  STATUS: $plain"
  return 0
}
print_test_card() { # id n total title scope group
  local id=$1 n=$2 total=$3 title=$4 scope=$5 group=$6 w k v hown=0
  w=$(( TERM_COLS > 110 ? 110 : TERM_COLS - 2 ))
  printf '\n\n%s%s%s\n' "$C_BOLD$C_BLUE" "$(_hr "$U_HL" "$w")" "$C_RESET"
  printf '  %s TEST %s %s %s %s   %s%s from %s%s   %s(%s · %s · started %s)%s\n' "$C_BOLD$C_WHITE$C_BGBLUE" "$C_RESET" \
    "$C_BOLD" "$title" "$C_RESET" "$C_BOLD$C_CYAN" "$n" "$total" "$C_RESET" "$C_DIM" "$id" "$group" "$(date '+%H:%M:%S')" "$C_RESET"
  printf '%s%s%s\n' "$C_BLUE" "$(_hr "$U_THIN" "$w")" "$C_RESET"
  while IFS='|' read -r k v; do
    [[ -n $k ]] || continue
    case $k in
      WHAT)   _card_line "$C_CYAN" "WHAT" "$v" ;;
      HOW)    hown=$(( hown + 1 )); if (( hown == 1 )); then _card_line "$C_BLUE" "HOW" "$hown. $v"; else _card_line "$C_BLUE" "" "$hown. $v"; fi ;;
      EXPECT) _card_line "$C_GREEN" "EXPECT" "$U_OK $v" ;;
      WATCH)  _card_line "$C_YELLOW" "WATCH" "$v" ;;
      TIME)   _card_line "$C_MAGENTA" "TIME" "$U_TIME $v" ;;
    esac
  done < <(test_brief "$id")
  _card_line "$C_DIM" "SCOPE" "$(scope_text "$scope")"
  card_status_line
  printf '%s%s%s\n' "$C_BLUE" "$(_hr "$U_THIN" "$w")" "$C_RESET"
  test_progress_strip
  printf '%s%s%s\n' "$C_BOLD$C_BLUE" "$(_hr "$U_HL" "$w")" "$C_RESET"
  test_brief "$id" | while IFS='|' read -r k v; do [[ -n $k ]] && _log "  $k: $v"; done
  return 0
}
run_test() { # id group scope title function
  local id=$1 group=$2 scope=$3 title=$4 fn=$5
  if ! group_selected "$group"; then
    printf '%s,%s,%s,%s,%s,"%s","%s"\n' "$id" "$group" "$scope" "SKIP" 0 "$title" "group not selected" >>"$RESULTS_CSV"
    T_ORDER+=("$id"); return 0
  fi
  T_ID=$id; T_RES="$RUN_DIR/results/$id.res"; mkdir -p "$RUN_DIR/results"; : >"$T_RES"
  T_NUM=$(( T_NUM + 1 ))
  print_test_card "$id" "$T_NUM" "$T_TOTAL" "$title" "$scope" "$group"
  _log "==== TEST $T_NUM from $T_TOTAL: $id [$group/$scope] $title"
  local start rc=0 dur status msg
  start=$(date +%s)
  set +e
  ( set -Eeuo pipefail; trap '_t_err $LINENO "$BASH_COMMAND"' ERR; "$fn" )
  rc=$?
  set -e
  dur=$(( $(date +%s) - start ))
  if grep -q '^FAIL|' "$T_RES"; then status=FAIL
  elif (( rc != 0 )); then status=FAIL; printf 'FAIL|test aborted (exit %s)\n' "$rc" >>"$T_RES"
  elif grep -q '^WARN|' "$T_RES"; then status=WARN
  elif grep -q '^PASS|' "$T_RES"; then status=PASS
  elif grep -q '^SKIP|' "$T_RES"; then status=SKIP
  else status=WARN; printf 'WARN|no assertions recorded\n' >>"$T_RES"; fi
  msg=$(grep -E "^${status}\|" "$T_RES" | head -n1 | cut -d'|' -f2- | tr '",' "' " || true)
  printf '%s,%s,%s,%s,%s,"%s","%s"\n' "$id" "$group" "$scope" "$status" "$dur" "$title" "$(_mask "$msg")" >>"$RESULTS_CSV"
  T_ORDER+=("$id"); T_STATUSES+=("$status")
  local col=$C_GREEN; [[ $status == FAIL ]] && col=$C_RED; [[ $status == WARN ]] && col=$C_YELLOW; [[ $status == SKIP ]] && col=$C_DIM
  local np nf nw; np=$(grep -c '^PASS|' "$T_RES" || true); nf=$(grep -c '^FAIL|' "$T_RES" || true); nw=$(grep -c '^WARN|' "$T_RES" || true)
  printf '\n  %s%s TEST %s from %s — %s:%s %s%s %s %s  %s(%s checks passed, %s failed, %s warnings; %s)%s\n' \
    "$C_BOLD" "$U_ARROW" "$T_NUM" "$T_TOTAL" "$title" "$C_RESET" "$C_BOLD$C_WHITE$(status_bg "$status")" " $status " "$C_RESET" "" \
    "$C_DIM" "$np" "$nf" "$nw" "$(fmt_dur "$dur")" "$C_RESET"
}

# ---------- background SQL load generator (client availability probes) ------
LOADGEN_SH='dur=$1; h=$2; d=$3; u=$4; IFS= read -r VSQL_PASSWORD; export VSQL_PASSWORD
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 8"
end=$(( $(date +%s) + dur ))
while [ "$(date +%s)" -lt "$end" ]; do
  s=$(date +%s%N)
  if $TO /opt/vertica/bin/vsql -m prefer -X -q -At -h "$h" -d "$d" -U "$u" -c "SELECT COUNT(*) FROM lab.sales WHERE sale_id % 1000 = 7" >/dev/null 2>&1; then r=OK; else r=FAIL; fi
  e=$(date +%s%N); echo "$(date +%s) $r $(( (e - s) / 1000000 ))"
  sleep 1
done'
LOAD_PID=""; LOAD_FILE=""; LOAD_END=0; LOAD_AVAIL=0; LOAD_MAX_OUTAGE=0; LOAD_RECOVERED=0
start_load() { # name duration host db
  LOAD_FILE="$RUN_DIR/load-$1.log"; : >"$LOAD_FILE"
  printf '%s\n' "$DB_PASSWORD" | timeout $(( $2 + 30 )) "${KC[@]}" exec -i -n "$NS" "$CLIENT_POD" -c client -- \
    sh -c "$LOADGEN_SH" sh "$2" "$3" "$4" "$DB_USER" >"$LOAD_FILE" 2>&1 &
  LOAD_PID=$!; BG_PIDS+=("$LOAD_PID"); LOAD_END=$(( $(date +%s) + $2 ))
  t_info "Client load generator started: 1 query/s via service $3 for $2s (simulates an application)"
}
load_stats() { # file -> "ok fail"
  local s; s=$(awk '$2=="OK"{o++} $2=="FAIL"{f++} END{printf "%d %d", o+0, f+0}' "$1" 2>/dev/null || true)
  printf '%s\n' "${s:-0 0}"
}
load_status_text() {
  [[ -n $LOAD_FILE ]] || return 0
  local o=0 f=0; read -r o f < <(load_stats "$LOAD_FILE") || true
  printf ' | client probes OK=%s FAIL=%s' "${o:-0}" "${f:-0}"
}
finish_load() { # name -> prints availability bar & metrics
  if [[ -n $LOAD_PID ]]; then
    local left=$(( LOAD_END - $(date +%s) ))
    if (( left > 0 )); then t_info "Recovery finished before the ${LOAD_SECONDS}s client load window — waiting ${left}s for the load generator to finish"; fi
    wait "$LOAD_PID" 2>/dev/null || true
  fi
  local o=0 f=0 tot avail bar=""
  read -r o f < <(load_stats "$LOAD_FILE") || true; o=${o:-0}; f=${f:-0}; tot=$(( o + f ))
  if (( tot == 0 )); then t_warn "Load generator produced no samples"; return 0; fi
  # Time-based view: every second of the window is coloured by the query that was running in it
  # (a query that hangs for 8s and then fails paints 8 seconds red). Output: okbar|badbar|okSecs|totSecs|maxOutage|last
  local tl oks tots maxo last
  tl=$(awk '{ n++; E[n]=$1; L[n]=$3/1000.0; R[n]=$2 }
    END {
      if (n == 0) { print "||0|0|0|NONE"; exit }
      t0 = int(E[1] - L[1]); t1 = E[n]; prev = R[1]; j = 1
      for (t = t0; t <= t1; t++) {
        while (j < n && E[j] < t) j++
        c = R[j]; if (int(E[j] - L[j]) > t) c = prev
        if (c == "OK") { ok++; run = 0; b = b "1" } else { run++; if (run > mo) mo = run; b = b "0" }
        tot++; prev = c
      }
      print b "|" ok + 0 "|" tot + 0 "|" mo + 0 "|" R[n]
    }' "$LOAD_FILE")
  local bits; IFS='|' read -r bits oks tots maxo last <<<"$tl"
  local i ch out=""
  for (( i = 0; i < ${#bits} && i < 300; i++ )); do
    ch=${bits:$i:1}
    if [[ $ch == 1 ]]; then out+="$C_GREEN$U_BAR_OK"; else out+="$C_RED$U_BAR_FAIL"; fi
  done
  printf '    %sclient timeline%s %s%s\n' "$C_DIM" "$C_RESET" "$out" "$C_RESET"
  printf '    %s(1 block = 1 second: %s%s%s%s = application queries succeeding, %s%s%s%s = outage / query stalled or failed)%s\n' "$C_DIM" \
    "$C_RESET$C_GREEN" "$U_BAR_OK" "$C_RESET" "$C_DIM" "$C_RESET$C_RED" "$U_BAR_FAIL" "$C_RESET" "$C_DIM" "$C_RESET"
  avail=$(awk -v o="${oks:-0}" -v t="${tots:-0}" 'BEGIN{ if (t > 0) printf "%.1f", 100*o/t; else print "0.0" }')
  metric "$1.client_queries" "$o" "ok" "$f failed or timed out"
  metric "$1.client_availability" "$avail" "%" "time-weighted over the ${tots}s window"
  metric "$1.longest_outage" "${maxo:-0}" "s" "longest continuous period without a successful query"
  local maxlat; maxlat=$(awk '$2=="OK"{if($3>m)m=$3} END{print m+0}' "$LOAD_FILE")
  metric "$1.max_ok_latency" "$maxlat" "ms"
  LOAD_PID=""; LOAD_AVAIL=$avail; LOAD_MAX_OUTAGE=${maxo:-0}; LOAD_RECOVERED=0
  if [[ $last == OK ]]; then LOAD_RECOVERED=1; fi
}
# PASS when the application recovered on its own (last queries succeed); report the outage honestly
assert_client_recovered() { # what
  if (( LOAD_RECOVERED )); then
    t_pass "Client application recovered automatically after the $1: longest outage ${LOAD_MAX_OUTAGE}s, availability ${LOAD_AVAIL}% over the ${LOAD_SECONDS}s window"
  else
    t_warn "Client queries were still failing at the end of the ${LOAD_SECONDS}s window (availability ${LOAD_AVAIL}%) — try LOAD_SECONDS=120"
  fi
}

# ---------- helpers used by tests --------------------------------------------
pod_ip() { kc -n "$NS" get pod "$1" -o jsonpath='{.status.podIP}' 2>/dev/null || true; }
pod_node() { kc -n "$NS" get pod "$1" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true; }
pod_uid() { kc -n "$NS" get pod "$1" -o jsonpath='{.metadata.uid}' 2>/dev/null || true; }
vnode_of_pod() { local ip; ip=$(pod_ip "$1"); sql1 "${VDB}-primary" "$DB_NAME" "SELECT node_name FROM nodes WHERE node_address='$ip';"; }
node_state_via() { # surviving_pod_ip db vnode
  vsql_t 20 "$1" "$2" "SELECT node_state FROM nodes WHERE node_name='$3';" 2>/dev/null | tr -d '[:space:]'
}
up_count_via() { vsql_t 25 "$1" "$2" "SELECT COUNT(*) FROM nodes WHERE node_state='UP';" 2>/dev/null | tr -d '[:space:]'; }
other_ready_pod() { # vdbname exclude_pod -> name of another Ready pod
  vdb_pods_json "$1" | jq -r --arg x "$2" '[.[] | select(.metadata.name != $x) | select(any(.status.conditions[]?; .type=="Ready" and .status=="True")) | .metadata.name][0] // empty'
}
probe_node_state() { # surv_ip db vnode want(UP|notUP)
  local s; s=$(node_state_via "$1" "$2" "$3" || true); printf '%s is %s%s' "$3" "${s:-?}" "$(load_status_text)"
  if [[ $4 == UP ]]; then [[ $s == UP ]]; else [[ -n $s && $s != UP ]]; fi
}
probe_db_up_n() { # host db n
  local u; u=$(up_count_via "$1" "$2" || true); printf 'Vertica nodes UP %s/%s%s' "${u:-?}" "$3" "$(load_status_text)"
  [[ $u =~ ^[0-9]+$ ]] && (( u >= $3 ))
}
ensure_dataset() {
  local c; c=$(sql1 "${VDB}-primary" "$DB_NAME" "SELECT COUNT(*) FROM tables WHERE table_schema='lab' AND table_name='sales';" || echo 0)
  if [[ $c != 1 ]]; then info "Dataset lab.sales missing — loading it now"; load_dataset "${VDB}-primary" "$DB_NAME" "$(state_get SALES_ROWS 2000000)"; fi
}
load_dataset() { # host db rows
  local host=$1 db=$2 rows=$3
  vsql_c "$host" "$db" "
CREATE SCHEMA IF NOT EXISTS lab;
DROP TABLE IF EXISTS lab.sales CASCADE; DROP TABLE IF EXISTS lab.customers CASCADE;
DROP TABLE IF EXISTS lab.products CASCADE; DROP TABLE IF EXISTS lab.nums CASCADE;
CREATE TABLE lab.nums AS
  SELECT (ROW_NUMBER() OVER (ORDER BY slice_time) - 1)::INT AS n
  FROM (SELECT slice_time FROM (SELECT '2000-01-01 00:00:00'::TIMESTAMP AS t UNION ALL SELECT '2000-01-01 02:46:39'::TIMESTAMP) s
        TIMESERIES slice_time AS '1 second' OVER (ORDER BY t)) x;
CREATE TABLE lab.customers (customer_id INT NOT NULL PRIMARY KEY, customer_name VARCHAR(40), region VARCHAR(16),
  segment VARCHAR(16), signup_date DATE) ORDER BY customer_id UNSEGMENTED ALL NODES;
INSERT INTO lab.customers SELECT n, 'customer_'||n,
  CASE n%5 WHEN 0 THEN 'NORTH' WHEN 1 THEN 'SOUTH' WHEN 2 THEN 'EAST' WHEN 3 THEN 'WEST' ELSE 'CENTRAL' END,
  CASE n%3 WHEN 0 THEN 'CONSUMER' WHEN 1 THEN 'SMB' ELSE 'ENTERPRISE' END, DATE '2020-01-01' + (n % 1500) FROM lab.nums;
CREATE TABLE lab.products (product_id INT NOT NULL PRIMARY KEY, category VARCHAR(32), price NUMERIC(10,2))
  ORDER BY product_id UNSEGMENTED ALL NODES;
INSERT INTO lab.products SELECT n,
  CASE n%8 WHEN 0 THEN 'ELECTRONICS' WHEN 1 THEN 'BOOKS' WHEN 2 THEN 'GROCERY' WHEN 3 THEN 'TOYS'
           WHEN 4 THEN 'SPORTS' WHEN 5 THEN 'HOME' WHEN 6 THEN 'BEAUTY' ELSE 'AUTO' END,
  (10 + (n % 490))::NUMERIC(10,2) FROM lab.nums WHERE n < 1000;
CREATE TABLE lab.sales (sale_id INT NOT NULL, sale_ts TIMESTAMP NOT NULL, customer_id INT NOT NULL, product_id INT NOT NULL,
  quantity INT, amount NUMERIC(14,2), channel VARCHAR(10))
  ORDER BY sale_ts, customer_id SEGMENTED BY HASH(sale_id) ALL NODES
  PARTITION BY (YEAR(sale_ts)*100 + MONTH(sale_ts));
INSERT /*+LABEL(lab_load_sales)*/ INTO lab.sales
SELECT s.sale_id, s.sale_ts, s.customer_id, s.product_id, s.quantity, (s.quantity * p.price)::NUMERIC(14,2), s.channel
FROM (SELECT a.n*10000 + b.n AS sale_id,
             TIMESTAMPADD(SECOND, ((a.n*10000 + b.n) * 37) % 63072000, TIMESTAMP '2024-01-01 00:00:00') AS sale_ts,
             ABS(HASH(a.n, b.n)) % 10000 AS customer_id,
             ABS(HASH(b.n, a.n, 7)) % 1000 AS product_id,
             1 + ABS(HASH(a.n + b.n)) % 5 AS quantity,
             CASE ABS(HASH(a.n, b.n, 3)) % 3 WHEN 0 THEN 'WEB' WHEN 1 THEN 'STORE' ELSE 'MOBILE' END AS channel
      FROM lab.nums a CROSS JOIN lab.nums b
      WHERE a.n < CEIL($rows/10000) AND a.n*10000 + b.n < $rows) s
JOIN lab.products p ON p.product_id = s.product_id;
COMMIT;
SELECT ANALYZE_STATISTICS('lab.sales');
" >/dev/null
}

# ---------- test emergency restore (EXIT trap in --test) ---------------------
test_emergency_restore() {
  docker_ok || return 0
  local c
  for c in $(lab_containers); do
    if [[ $(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null) == paused ]]; then
      warn "Safety net: unpausing $c (left paused by an interrupted node-failure test)"; docker unpause "$c" >/dev/null 2>&1 || true
    fi
  done
  if k8s_reachable; then
    timeout 30 "${KC[@]}" -n "$NS" delete networkpolicy vlab-restrict-5433 --ignore-not-found >/dev/null 2>&1 || true
    timeout 30 "${KC[@]}" -n "$NS" delete pod vlab-intruder --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
  return 0
}

#==============================================================================
# TESTS
#==============================================================================
T_HOST="${VDB}-primary"

t01_health() { health_checks "$VDB" "$DB_NAME" 3 test; }

health_checks() { # vdb db nodes mode(test|status)
  local vdb=$1 db=$2 n=$3 out r t
  if nodes_ready_probe >/dev/null; then t_pass "Kubernetes: 4/4 nodes Ready"; else t_fail "Kubernetes nodes not all Ready: $(nodes_ready_probe || true)"; fi
  if operator_probe >/dev/null; then t_pass "VerticaDB operator Deployment available"; else t_fail "Operator not available"; fi
  if kc get validatingwebhookconfigurations -o name 2>/dev/null | grep -qi vertica; then t_pass "Admission webhook registered (invalid CR changes are rejected)"; else t_warn "Vertica validating webhook not found"; fi
  if minio_probe >/dev/null; then t_pass "Communal storage (MinIO) ready"; else t_fail "MinIO not ready"; fi
  if [[ $(state_get OAUTH_INSTALLED) == 1 ]]; then
    if keycloak_probe >/dev/null; then t_pass "Identity provider (Keycloak) ready"; else t_fail "Keycloak not ready"; fi
  fi
  read -r r t < <(pods_ready_count "$vdb")
  if [[ $r -ge $n ]]; then t_pass "VerticaDB pods Ready: $r/$n"; else t_fail "VerticaDB pods Ready: $r/$n"; fi
  local pvc; pvc=$(kc -n "$NS" get pvc -o json | jq --arg p "local-data-$vdb-primary-" '[.items[] | select(.metadata.name|startswith($p))] | "\([.[]|select(.status.phase=="Bound")]|length)/\(length)"' -r)
  if [[ ${pvc%%/*} -ge $n ]]; then t_pass "Persistent volume claims Bound: $pvc"; else t_warn "PVC Bound: $pvc"; fi
  local restarts; restarts=$(vdb_pods_json "$vdb" | jq '[.[].status.containerStatuses[]?.restartCount] | add // 0')
  t_info "Container restarts (cumulative, includes earlier failure tests): $restarts"
  local up; up=$(up_count_via "${vdb}-primary" "$db" || true)
  if [[ $up =~ ^[0-9]+$ && $up -ge $n ]]; then t_pass "Vertica nodes UP: $up/$n"; else t_fail "Vertica nodes UP: ${up:-?}/$n"; fi
  out=$(vsql_t 30 "${vdb}-primary" "$db" "SELECT designed_fault_tolerance||'|'||current_fault_tolerance||'|'||node_count||'|'||node_down_count FROM system;" || true)
  IFS='|' read -r dk ck nc nd <<<"$out"
  t_info "K-safety designed=$dk current=$ck nodes=$nc down=$nd"
  if [[ $n -ge 3 ]]; then
    if [[ ${ck:-0} -ge 1 ]]; then t_pass "Database is K-safe (current fault tolerance $ck)"; else t_warn "Current fault tolerance ${ck:-?} (< 1)"; fi
  fi
  local comm; comm=$(sql1 "${vdb}-primary" "$db" "SELECT COUNT(*) FROM storage_locations WHERE sharing_type='COMMUNAL';" || echo 0)
  if [[ ${comm:-0} -ge 1 ]]; then t_pass "Eon communal storage location registered"; else t_fail "No communal storage location"; fi
  local lic; lic=$(vsql_t 30 "${vdb}-primary" "$db" "SELECT GET_COMPLIANCE_STATUS();" 2>/dev/null | tr '\n' ' ' | cut -c1-200 || true)
  t_info "License compliance: ${lic:-n/a}"
  local qos; qos=$(vdb_pods_json "$vdb" | jq -r '[.[].status.qosClass] | unique | join(",")')
  if [[ $qos == Guaranteed ]]; then t_pass "Vertica pods QoS class: Guaranteed (requests = limits)"; else t_info "Vertica pods QoS class: $qos (NMA sidecar defaults may make it Burstable)"; fi
}

t02_workload() {
  local rows; rows=$(state_get SALES_ROWS 2000000)
  t_info "Building a star schema (customers 10k, products 1k, sales $rows rows) with set-based SQL generation"
  local s e; s=$(date +%s%N)
  load_dataset "$T_HOST" "$DB_NAME" "$rows"
  e=$(date +%s%N)
  local ms=$(( (e - s) / 1000000 )); (( ms < 1 )) && ms=1
  metric "load.sales_rows" "$rows" "rows"
  metric "load.elapsed" "$(( ms / 1000 ))" "s"
  metric "load.throughput" "$(( rows * 1000 / ms ))" "rows/s" "INSERT..SELECT incl. join, 3 nodes"
  local c; c=$(sql1 "$T_HOST" "$DB_NAME" "SELECT COUNT(*) FROM lab.sales;")
  [[ $c == "$rows" ]] && t_pass "Row count verified: lab.sales = $c" || t_fail "lab.sales has $c rows, expected $rows"
  local orphans; orphans=$(sql1 "$T_HOST" "$DB_NAME" "SELECT COUNT(*) FROM lab.sales s LEFT JOIN lab.customers c ON c.customer_id=s.customer_id WHERE c.customer_id IS NULL;")
  [[ $orphans == 0 ]] && t_pass "Referential integrity: 0 orphan sales rows" || t_fail "$orphans orphan rows"
  vsql_show "$T_HOST" "$DB_NAME" "Data distribution across nodes (segmentation)" \
    "SELECT node_name, SUM(row_count) AS rows_on_node, SUM(used_bytes)//1048576 AS used_mb FROM projection_storage WHERE anchor_table_name='sales' GROUP BY 1 ORDER BY 1;" || true
  local skew; skew=$(vsql_t 60 "$T_HOST" "$DB_NAME" "SELECT ROUND(MAX(r)/NULLIFZERO(MIN(r)),2) FROM (SELECT node_name, SUM(row_count) r FROM projection_storage WHERE anchor_table_name='sales' GROUP BY 1) x;" | tr -d '[:space:]' || true)
  metric "load.segmentation_skew" "${skew:-n/a}" "max/min" "1.00 = perfectly even"
  vsql_show "$T_HOST" "$DB_NAME" "Sample business query: revenue by channel" \
    "SELECT channel, COUNT(*) AS orders, SUM(amount) AS revenue FROM lab.sales GROUP BY 1 ORDER BY 3 DESC;" || true
}

t03_perf() {
  local tag; tag="r$(date +%H%M%S)"
  declare -A Q=(
    [q1]="SELECT /*+LABEL(lab_q1_@TAG@_@RUN@)*/ c.region, DATE_TRUNC('month', s.sale_ts)::DATE AS month, SUM(s.amount) revenue, COUNT(*) orders FROM lab.sales s JOIN lab.customers c ON c.customer_id = s.customer_id GROUP BY 1,2 ORDER BY 1,2;"
    [q2]="SELECT /*+LABEL(lab_q2_@TAG@_@RUN@)*/ * FROM (SELECT customer_id, SUM(amount) rev, RANK() OVER (ORDER BY SUM(amount) DESC) rnk FROM lab.sales GROUP BY customer_id) t WHERE rnk <= 10;"
    [q3]="SELECT /*+LABEL(lab_q3_@TAG@_@RUN@)*/ d, daily, AVG(daily) OVER (ORDER BY d ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) ma7 FROM (SELECT sale_ts::DATE d, SUM(amount) daily FROM lab.sales GROUP BY 1) x ORDER BY d;"
    [q4]="SELECT /*+LABEL(lab_q4_@TAG@_@RUN@)*/ p.category, COUNT(DISTINCT s.customer_id) FROM lab.sales s JOIN lab.products p ON p.product_id = s.product_id GROUP BY 1;"
    [q5]="SELECT /*+LABEL(lab_q5_@TAG@_@RUN@)*/ * FROM lab.sales WHERE sale_id = 123457;"
    [q6]="SELECT /*+LABEL(lab_q6_@TAG@_@RUN@)*/ DISTINCT channel, PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY amount) OVER (PARTITION BY channel) FROM lab.sales;"
  )
  declare -A QN=([q1]="star join + GROUP BY month/region" [q2]="top-10 customers RANK()" [q3]="7-day moving average window"
                 [q4]="distinct customers per category" [q5]="point lookup" [q6]="90th percentile per channel")
  t_info "Running 6 analytic queries x 3 runs; timings read server-side from v_monitor.query_requests"
  local q r sql
  for q in q1 q2 q3 q4 q5 q6; do
    for r in 1 2 3; do
      sql=${Q[$q]//@TAG@/$tag}; sql=${sql//@RUN@/r$r}
      vsql_c "$T_HOST" "$DB_NAME" "$sql" >/dev/null || t_fail "$q run $r failed"
    done
  done
  sleep 2
  local rows; rows=$(vsql_c "$T_HOST" "$DB_NAME" "SELECT request_label, request_duration_ms FROM v_monitor.query_requests WHERE request_label LIKE 'lab_q%_${tag}_r%' AND success ORDER BY 1;" || true)
  printf '    %s%-6s %-40s %10s %10s%s\n' "$C_BOLD" "QUERY" "DESCRIPTION" "MEDIAN ms" "MIN ms" "$C_RESET"
  for q in q1 q2 q3 q4 q5 q6; do
    local vals med mn
    vals=$(awk -F'|' -v p="lab_${q}_${tag}_" 'index($1,p)==1{print $2}' <<<"$rows" | sort -n)
    if [[ -z $vals ]]; then t_warn "$q: no timing captured"; continue; fi
    med=$(awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}' <<<"$vals"); mn=$(head -n1 <<<"$vals")
    printf '    %-6s %-40s %10s %10s\n' "$q" "${QN[$q]}" "$med" "$mn"
    printf '%s,%s.median,%s,ms,"%s"\n' "$T_ID" "$q" "$med" "${QN[$q]}" >>"$PERF_CSV"
  done
  t_pass "Analytic query benchmark completed (results in perf.csv)"

  t_info "Eon depot effect: clear the depot cache, run q1 cold (reads communal S3), then warm"
  vsql_c "$T_HOST" "$DB_NAME" "SELECT CLEAR_DATA_DEPOT();" >/dev/null 2>&1 || t_info "CLEAR_DATA_DEPOT not permitted; cold run may be partially warm"
  local cold warm
  sql=${Q[q1]//@TAG@/$tag}
  vsql_c "$T_HOST" "$DB_NAME" "${sql//@RUN@/cold}" >/dev/null || t_warn "q1 cold run failed"
  vsql_c "$T_HOST" "$DB_NAME" "${sql//@RUN@/warm}" >/dev/null || t_warn "q1 warm run failed"
  sleep 2
  cold=$(sql1 "$T_HOST" "$DB_NAME" "SELECT MAX(request_duration_ms) FROM v_monitor.query_requests WHERE request_label='lab_q1_${tag}_cold';" || true)
  warm=$(sql1 "$T_HOST" "$DB_NAME" "SELECT MAX(request_duration_ms) FROM v_monitor.query_requests WHERE request_label='lab_q1_${tag}_warm';" || true)
  metric "depot.q1_cold" "${cold:-n/a}" "ms" "data fetched from communal storage"
  metric "depot.q1_warm" "${warm:-n/a}" "ms" "served from local depot"
  if [[ -n $cold && -n $warm ]]; then t_pass "Depot cold/warm comparison captured (cold ${cold} ms vs warm ${warm} ms)"; else t_warn "Depot cold/warm timings not captured"; fi

  local C=8 M=5
  t_info "Concurrency test: $C parallel sessions x $M queries (q2) through the load-balanced service"
  local out
  out=$(printf '%s\n' "$DB_PASSWORD" | timeout 900 "${KC[@]}" exec -i -n "$NS" "$CLIENT_POD" -c client -- sh -c '
    C=$1; M=$2; h=$3; d=$4; u=$5; IFS= read -r VSQL_PASSWORD; export VSQL_PASSWORD
    s=$(date +%s%N); i=0
    while [ $i -lt $C ]; do
      ( j=0; while [ $j -lt $M ]; do /opt/vertica/bin/vsql -m prefer -X -q -At -h "$h" -d "$d" -U "$u" -c "SELECT customer_id, SUM(amount) FROM lab.sales GROUP BY 1 ORDER BY 2 DESC LIMIT 10" >/dev/null 2>&1 || echo ERR; j=$((j+1)); done ) &
      i=$((i+1))
    done; wait
    e=$(date +%s%N); echo "ELAPSED $(( (e - s) / 1000000 ))"' sh "$C" "$M" "$T_HOST" "$DB_NAME" "$DB_USER" 2>&1 || true)
  local el errs; el=$(awk '/^ELAPSED/{print $2}' <<<"$out"); errs=$(grep -c '^ERR' <<<"$out" || true)
  if [[ -n $el && $el -gt 0 ]]; then
    metric "concurrency.sessions" "$C" "sessions"
    metric "concurrency.throughput" "$(awk -v n=$((C*M)) -v ms="$el" 'BEGIN{printf "%.2f", n*1000/ms}')" "queries/s"
    metric "concurrency.errors" "$errs" "errors"
    [[ $errs == 0 ]] && t_pass "Concurrent workload: $((C*M)) queries, 0 errors" || t_fail "Concurrent workload had $errs errors"
  else t_fail "Concurrency test did not complete"; fi

  t_info "Bulk load (ETL) test: generate 500k CSV rows in the client pod and COPY FROM LOCAL"
  vsql_c "$T_HOST" "$DB_NAME" "DROP TABLE IF EXISTS lab.web_events; CREATE TABLE lab.web_events (event_id INT, event_ts TIMESTAMP, customer_id INT, url VARCHAR(64), latency_ms INT) SEGMENTED BY HASH(event_id) ALL NODES;" >/dev/null
  out=$(printf '%s\n' "$DB_PASSWORD" | timeout 900 "${KC[@]}" exec -i -n "$NS" "$CLIENT_POD" -c client -- sh -c '
    h=$1; d=$2; u=$3; IFS= read -r VSQL_PASSWORD; export VSQL_PASSWORD
    command -v awk >/dev/null 2>&1 || { echo NOAWK; exit 0; }
    awk "BEGIN{for(i=0;i<500000;i++) printf \"%d,2025-%02d-%02d %02d:%02d:%02d,%d,/page/%d,%d\n\", i, 1+i%12, 1+i%28, i%24, i%60, (i*7)%60, i%10000, i%250, 5+(i*13)%900}" > /tmp/events.csv
    s=$(date +%s%N)
    /opt/vertica/bin/vsql -m prefer -X -q -At -h "$h" -d "$d" -U "$u" -c "COPY lab.web_events FROM LOCAL '"'"'/tmp/events.csv'"'"' DELIMITER '"'"','"'"' ABORT ON ERROR" || echo COPYFAIL
    e=$(date +%s%N); echo "ELAPSED $(( (e - s) / 1000000 ))"; rm -f /tmp/events.csv' sh "$T_HOST" "$DB_NAME" "$DB_USER" 2>&1 || true)
  if grep -q NOAWK <<<"$out"; then t_skip "awk not available in client image — COPY test skipped"
  elif grep -q COPYFAIL <<<"$out"; then t_fail "COPY FROM LOCAL failed"
  else
    el=$(awk '/^ELAPSED/{print $2}' <<<"$out"); [[ $el =~ ^[0-9]+$ && $el -gt 0 ]] || el=1
    local cnt; cnt=$(sql1 "$T_HOST" "$DB_NAME" "SELECT COUNT(*) FROM lab.web_events;"); [[ $cnt =~ ^[0-9]+$ ]] || cnt=0
    metric "copy.rows" "$cnt" "rows"; metric "copy.throughput" "$(( cnt * 1000 / el ))" "rows/s" "COPY FROM LOCAL client->cluster"
    [[ $cnt == 500000 ]] && t_pass "COPY loaded 500,000 rows" || t_fail "COPY loaded $cnt rows"
  fi
}

t04_storage() {
  local p pvcs
  pvcs=$(kc -n "$NS" get pvc -o json | jq -r --arg p "local-data-$VDB-" '.items[] | select(.metadata.name|startswith($p)) | "\(.metadata.name) \(.status.phase) \(.spec.storageClassName) \(.status.capacity.storage // "-") \(.spec.volumeName)"')
  printf '    %s%-34s %-7s %-9s %-8s %s%s\n' "$C_BOLD" "PVC" "PHASE" "CLASS" "SIZE" "PV" "$C_RESET"
  while read -r a b c d e; do if [[ -n $a ]]; then printf '    %-34s %-7s %-9s %-8s %s\n' "$a" "$b" "$c" "$d" "$e"; fi; done <<<"$pvcs"
  local nb; nb=$(grep -c ' Bound ' <<<"$pvcs" || true)
  [[ $nb -ge 3 ]] && t_pass "Each Vertica pod has its own Bound PersistentVolume (catalog + depot)" || t_fail "Only $nb Bound PVCs"
  p="${VDB}-primary-0"
  local df; df=$(kc -n "$NS" exec "$p" -c server -- df -h /home/dbadmin/local-data 2>/dev/null | tail -n1 || true)
  [[ -n $df ]] && t_pass "Local data volume mounted in pod: $df" || t_warn "Could not read local-data mount"
  vsql_show "$T_HOST" "$DB_NAME" "Storage locations (catalog/data/depot local, data in communal S3)" \
    "SELECT node_name, location_usage, sharing_type, LEFT(location_path,60) AS path FROM storage_locations ORDER BY node_name, location_usage;" || true
  vsql_show "$T_HOST" "$DB_NAME" "Depot usage per node" \
    "SELECT node_name, (disk_space_used_mb) AS used_mb, (disk_space_free_mb) AS free_mb, storage_usage FROM v_monitor.disk_storage WHERE storage_usage IN ('DEPOT','DATA,TEMP','CATALOG') ORDER BY 1,4;" || true
  if [[ $(state_get MINIO_MC) == 1 ]]; then
    local cp objs; cp=$(state_get COMMUNAL_PATH); cp=${cp#s3://}
    objs=$(kc -n "$MINIO_NS" exec deploy/minio -- mc ls --recursive "local/$cp" 2>/dev/null | wc -l || echo 0)
    metric "communal.objects" "$objs" "objects" "in s3://$cp"
    (( objs > 0 )) && t_pass "Communal storage holds $objs objects (data survives loss of every pod)" || t_fail "No objects in communal path"
    local du; du=$(kc -n "$MINIO_NS" exec deploy/minio -- mc du "local/$cp" 2>/dev/null | tail -n1 || true); t_info "Communal usage: ${du:-n/a}"
  else
    local n; n=$(sql1 "$T_HOST" "$DB_NAME" "SELECT COUNT(*) FROM storage_containers;" || echo 0)
    (( n > 0 )) && t_pass "Storage containers present: $n (persisted in communal storage)" || t_fail "No storage containers"
  fi
  local rc; rc=$(kc get sc standard -o jsonpath='{.reclaimPolicy}/{.volumeBindingMode}' 2>/dev/null || true)
  t_info "StorageClass 'standard' (rancher local-path): reclaim/binding = $rc  — production: use replicated/network CSI storage"
}

_bearer_call() { # token url -> "HTTP-code|first 60 characters of the body" (token passed on stdin, never on a command line)
  local out code body
  out=$(printf 'header = "Authorization: Bearer %s"\n' "$1" | docker exec -i "$(cp_node)" curl -sk -K - -w '\n%{http_code}' --max-time 15 "$2" 2>/dev/null || true)
  code=${out##*$'\n'}; body=${out%$'\n'*}; [[ $code =~ ^[0-9]{3}$ ]] || { code=000; body=""; }
  body=$(tr '\n' ' ' <<<"$body" | cut -c1-60); printf '%s|%s' "$code" "${body% }"
}
# Vertica 26.3 docs, Prometheus integration, "Bearer token authentication": the operator's /metrics endpoint
# accepts the pod's Kubernetes service-account token (a JWT signed by the API server). The chart binds the
# metrics-reader role to system:authenticated (documented), so any valid cluster identity may read metrics.
jwt_bearer_checks() { # metrics-url valid-token
  local url=$1 tok=$2 jh jp bad other ro r
  jh=$(jwt_part "$tok" 0); jp=$(jwt_part "$tok" 1)
  if [[ -n $jp ]] && jq -e .sub >/dev/null 2>&1 <<<"$jp"; then
    t_pass "The service-account token is a signed JWT (machine-to-machine identity): alg=$(jq -r '.alg' <<<"$jh"), iss=$(jq -r '.iss' <<<"$jp"), sub=$(jq -r '.sub' <<<"$jp"), aud=$(jq -c '.aud' <<<"$jp"), lifetime $(( $(jq -r '.exp' <<<"$jp") - $(jq -r '.iat' <<<"$jp") )) s"
  else t_warn "Could not decode the service-account token as a JWT"; return 0; fi
  # 1) one character changed in the middle of the signature
  bad=$(awk -F. '{s=$3; i=int(length(s)/2); c=substr(s,i,1); r=(c=="A")?"B":"A"; print $1"."$2"."substr(s,1,i-1) r substr(s,i+1)}' <<<"$tok"); SECRET_VALUES+=("$bad")
  r=$(_bearer_call "$bad" "$url")
  [[ ${r%%|*} != 200 && $r != *vertica_* ]] && t_pass "JWT with a tampered signature is rejected (HTTP ${r%%|*}: ${r#*|})" || t_fail "Tampered JWT was accepted (HTTP ${r%%|*})"
  # 2) valid signature, but issued for another audience
  other=$(kc -n "$NS" create token vlab-client --audience=not-kubernetes --duration=10m 2>/dev/null || true); SECRET_VALUES+=("$other")
  r=$(_bearer_call "$other" "$url")
  [[ ${r%%|*} != 200 && $r != *vertica_* ]] && t_pass "JWT issued for another audience is rejected (HTTP ${r%%|*}: ${r#*|})" || t_fail "Wrong-audience JWT was accepted (HTTP ${r%%|*})"
  local why; why=$(kc -n "$OP_NS" logs deploy/"$(kc -n "$OP_NS" get deploy -o name 2>/dev/null | head -n1 | cut -d/ -f2)" --since=2m 2>/dev/null | grep -o 'invalid bearer token[^"]*' | tail -n1 || true)
  [[ -n $why ]] && t_info "Operator log for the rejected tokens: \"${why:0:110}\""
  # 3) a valid JWT of another service account: authenticated, and authorised by the documented binding
  ro=$(kc -n "$NS" create token vlab-readonly --duration=10m 2>/dev/null || true); SECRET_VALUES+=("$ro")
  r=$(_bearer_call "$ro" "$url")
  if [[ ${r%%|*} == 200 ]]; then t_pass "A valid JWT of another service account is accepted: the chart binds metrics-reader to system:authenticated (documented default)"
    t_info "Production: bind the metrics-reader role only to the Prometheus service account instead of system:authenticated"
  else t_info "Valid JWT of another service account returned HTTP ${r%%|*} (metrics-reader binding restricted)"; fi
  return 0
}
t05_monitoring() {
  local i ok_top=0
  for i in $(seq 1 12); do
    if kc top nodes >/dev/null 2>&1; then ok_top=1; break; fi; sleep 10
  done
  if (( ok_top )); then
    t_pass "metrics-server: live resource metrics available"
    run --show --allow-fail kc top nodes
    run --show --allow-fail kc -n "$NS" top pods --containers
  else t_warn "metrics-server not serving metrics yet"; fi
  # operator metrics (HTTPS + RBAC bearer token)
  local svc ip port token code body
  svc=$(kc -n "$OP_NS" get svc -o name 2>/dev/null | grep -i metrics | head -n1 | cut -d/ -f2 || true)
  if [[ -n $svc ]]; then
    ip=$(kc -n "$OP_NS" get svc "$svc" -o jsonpath='{.spec.clusterIP}'); port=$(kc -n "$OP_NS" get svc "$svc" -o jsonpath='{.spec.ports[0].port}')
    token=$(kc -n "$NS" create token vlab-client --duration=10m 2>/dev/null || true); SECRET_VALUES+=("$token")
    body=$(printf 'header = "Authorization: Bearer %s"\n' "$token" | docker exec -i "$(cp_node)" curl -sk -K - --max-time 20 "https://$ip:$port/metrics" 2>/dev/null || true)
    if grep -q '^vertica_' <<<"$body"; then
      t_pass "Operator /metrics (HTTPS, RBAC-authorised token) exposes $(grep -c '^vertica_' <<<"$body") vertica_* samples"
      local fams nf more=""; fams=$(grep -E '^vertica_' <<<"$body" | sed -E 's/[{ ].*//; s/_(bucket|sum|count)$//' | sort -u)
      nf=$(grep -c . <<<"$fams" || true); (( nf > 6 )) && more=", …"
      t_info "Metric families ($nf): $(head -n 6 <<<"$fams" | paste -sd, - | sed 's/,/, /g')$more  (raw samples: log only)"
      _log "Operator /metrics raw vertica_* samples:"
      grep -E '^vertica_' <<<"$body" | head -n 60 | while IFS= read -r l; do _log "      $l"; done
    else t_warn "Operator metrics endpoint did not return vertica_* metrics (service $svc)"; fi
    code=$(docker exec "$(cp_node)" curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "https://$ip:$port/metrics" 2>/dev/null || echo 000)
    [[ $code == 401 || $code == 403 ]] && t_pass "Anonymous scrape of operator metrics is rejected (HTTP $code)" || t_warn "Anonymous metrics request returned HTTP $code"
    jwt_bearer_checks "https://$ip:$port/metrics" "$token"
  else t_warn "Operator metrics service not found"; fi
  # Vertica server Prometheus endpoint (HTTPS service :8443 /v1/metrics)
  local pip; pip=$(pod_ip "${VDB}-primary-0")
  code=$(printf 'user = "%s:%s"\n' "$DB_USER" "$DB_PASSWORD" | docker exec -i "$(cp_node)" curl -sk -K - -o /tmp/vlab-metrics.txt -w '%{http_code}' --max-time 20 "https://$pip:8443/v1/metrics" 2>/dev/null || echo 000)
  if [[ $code == 200 ]]; then
    local cnt; cnt=$(docker exec "$(cp_node)" sh -c 'grep -c "^vertica_" /tmp/vlab-metrics.txt; rm -f /tmp/vlab-metrics.txt' 2>/dev/null || echo 0)
    t_pass "Vertica server Prometheus endpoint https://<pod>:8443/v1/metrics — $cnt samples (TLS)"
  else
    docker exec "$(cp_node)" rm -f /tmp/vlab-metrics.txt 2>/dev/null || true
    t_warn "Server /v1/metrics returned HTTP $code (production uses mTLS client certificates — see Vertica docs 'Prometheus integration')"
  fi
  # SQL-level monitoring (system tables)
  vsql_show "$T_HOST" "$DB_NAME" "Resource pool status" "SELECT node_name, pool_name, memory_inuse_kb, running_query_count FROM v_monitor.resource_pool_status WHERE pool_name IN ('general','lab_bi_pool','lab_etl_pool') ORDER BY 1,2;" || true
  vsql_show "$T_HOST" "$DB_NAME" "Top 5 slowest lab queries (Data Collector)" "SELECT LEFT(request_label,24) label, request_duration_ms ms, LEFT(request,50) request FROM v_monitor.query_requests WHERE request_label LIKE 'lab_%' ORDER BY request_duration_ms DESC LIMIT 5;" || true
  t_pass "System-table monitoring (v_monitor.*) queried successfully"
  # Kubernetes events from the operator
  local ev; ev=$(kc -n "$NS" get events --field-selector "involvedObject.kind=VerticaDB" -o json 2>/dev/null | jq '.items | length' || echo 0)
  # Kubernetes keeps events for 1 hour only (kube-apiserver --event-ttl): a stable database has none - that is normal.
  if (( ev > 0 )); then t_pass "Operator emits Kubernetes events for the VerticaDB ($ev events in the last hour)"
  else t_info "No VerticaDB events in the last hour — expected while the database is stable (Kubernetes keeps events for 1 h; the operator emits them on changes, e.g. in T09-T14)"; fi
  local st; st=$(kc -n "$NS" get vdb "$VDB" -o json | jq -c '{subclusters: [.status.subclusters[]? | {name, upNodeCount, addedToDBCount}], conditions: [.status.conditions[]? | {type, status}]}' 2>/dev/null || true)
  t_info "VerticaDB status: ${st:0:300}"
  if [[ $ENABLE_MONITORING_STACK == true ]]; then
    local pr; pr=$(kc -n "$OP_NS" get pods --no-headers 2>/dev/null | grep -Ec 'prometheus|grafana' || true)
    (( pr > 0 )) && t_pass "Chart monitoring stack pods running: $pr" || t_fail "Prometheus/Grafana pods not found"
  else t_info "Chart Prometheus/Grafana stack disabled (ENABLE_MONITORING_STACK=true to enable)"; fi
}

# Vertica 26.3 docs: node-to-node traffic uses a control channel (Spread; EncryptSpreadComm) and a data channel
# (TLS configuration 'data_channel', set up by the operator from spec.interNodeTLS, mode VERIFY_CA).
internode_tls_checks() {
  if [[ $ENABLE_INTERNODE_TLS != true ]]; then t_warn "Inter-node TLS not enabled (ENABLE_INTERNODE_TLS=false) — recommended when the network between nodes is not trusted"; return 0; fi
  local dc spread isec st
  dc=$(sql1 "$T_HOST" "$DB_NAME" "SELECT mode||'|'||COALESCE(certificate,'')||'|'||COALESCE(ca_certificate,'') FROM tls_configurations WHERE name='data_channel';" || true)
  isec=$(kc -n "$NS" get vdb "$VDB" -o jsonpath='{.spec.interNodeTLS.secret}' 2>/dev/null || true)
  if [[ ${dc%%|*} == VERIFY_CA && -n $(cut -d'|' -f2 <<<"$dc") ]]; then
    t_pass "Data channel between nodes uses TLS: mode VERIFY_CA, certificate $(cut -d'|' -f2 <<<"$dc") from Kubernetes Secret ${isec:-n/a}"
  else t_fail "Data-channel TLS not active (data_channel = '${dc:-n/a}', expected VERIFY_CA with a certificate)"; fi
  spread=$(sql1 "$T_HOST" "$DB_NAME" "SELECT current_value FROM configuration_parameters WHERE parameter_name='EncryptSpreadComm' LIMIT 1;" || true)
  if [[ -n $spread && ${spread,,} != disabled ]]; then t_pass "Control channel (Spread) between nodes is encrypted (EncryptSpreadComm=$spread)"
  else t_fail "Spread control channel not encrypted (EncryptSpreadComm='${spread:-n/a}')"; fi
  st=$(kc -n "$NS" get vdb "$VDB" -o json 2>/dev/null | jq -r '[.status.tlsConfigs[]? | "\(.name)=\(.mode)"] | join(", ")' || true)
  if [[ $st == *interNode* || $st == *internode* ]]; then t_pass "Operator reports all TLS configurations: $st"
  else t_warn "Operator status does not list an interNode TLS configuration yet ($st)"; fi
  vsql_show "$T_HOST" "$DB_NAME" "SECURITY_CONFIG_CHECK('NETWORK') (documented internode check)" "SELECT SECURITY_CONFIG_CHECK('NETWORK');" || true
  return 0
}
t06_security() {
  local yaml; yaml=$(kc -n "$NS" get vdb "$VDB" -o yaml; kc -n "$NS" get sts -o yaml)
  if grep -qF -- "$DB_PASSWORD" <<<"$yaml"; then t_fail "Superuser password found in plain text in CR/StatefulSet"
  else t_pass "Superuser password only referenced via Secret (not present in CR / StatefulSet specs)"; fi
  local uid; uid=$(kc -n "$NS" exec "${VDB}-primary-0" -c server -- id -u 2>/dev/null || echo "?")
  [[ $uid != 0 && $uid != "?" ]] && t_pass "Vertica server container runs as non-root (uid $uid)" || t_warn "Server container uid: $uid"
  # Kubernetes RBAC least privilege
  local sa="system:serviceaccount:$NS:vlab-readonly"
  if kc auth can-i list pods -n "$NS" --as="$sa" >/dev/null 2>&1; then t_pass "RBAC: read-only SA can list pods"; else t_fail "RBAC: read-only SA cannot list pods"; fi
  if kc auth can-i delete verticadbs.vertica.com -n "$NS" --as="$sa" >/dev/null 2>&1; then t_fail "RBAC: read-only SA CAN delete VerticaDB"; else t_pass "RBAC: read-only SA is denied delete on VerticaDB"; fi
  if kc auth can-i get secrets -n "$NS" --as="$sa" >/dev/null 2>&1; then t_fail "RBAC: read-only SA can read Secrets"; else t_pass "RBAC: read-only SA is denied access to Secrets"; fi
  # Database RBAC
  vsql_c "$T_HOST" "$DB_NAME" "DROP USER IF EXISTS lab_reader CASCADE;" >/dev/null 2>&1 || true
  vsql_c "$T_HOST" "$DB_NAME" "CREATE USER lab_reader IDENTIFIED BY '$LAB_USER_PASSWORD'; GRANT USAGE ON SCHEMA lab TO lab_reader; GRANT SELECT ON lab.sales TO lab_reader;" >/dev/null
  local c; c=$(vsql_as 60 raw lab_reader "$LAB_USER_PASSWORD" "$T_HOST" "$DB_NAME" "SELECT COUNT(*) FROM lab.sales;" 2>/dev/null | tr -d '[:space:]' || true)
  [[ $c =~ ^[0-9]+$ ]] && t_pass "DB RBAC: lab_reader can SELECT ($c rows)" || t_fail "lab_reader could not SELECT"
  if vsql_as 60 raw lab_reader "$LAB_USER_PASSWORD" "$T_HOST" "$DB_NAME" "INSERT INTO lab.sales VALUES (-1, NOW(), 0, 0, 1, 1, 'X');" >/dev/null 2>&1; then
    t_fail "DB RBAC: lab_reader was able to INSERT"; else t_pass "DB RBAC: INSERT by read-only user is denied"; fi
  # failed login is audited
  vsql_as 30 raw lab_reader "wrong-password-xyz" "$T_HOST" "$DB_NAME" "SELECT 1;" >/dev/null 2>&1 || true
  sleep 2
  local lf; lf=$(sql1 "$T_HOST" "$DB_NAME" "SELECT COUNT(*) FROM v_monitor.login_failures WHERE user_name='lab_reader';" || echo 0)
  [[ ${lf:-0} -ge 1 ]] && t_pass "Failed login attempt recorded in v_monitor.login_failures ($lf)" || t_warn "Failed login not visible in login_failures"
  # TLS
  if [[ $ENABLE_DB_TLS == true ]]; then
    local ssl; ssl=$(VSQL_SSLMODE=require vsql_t 60 "$T_HOST" "$DB_NAME" "SELECT s.ssl_state FROM v_monitor.sessions s JOIN v_monitor.current_session c ON s.session_id = c.session_id;" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ -n $ssl && $ssl != None ]]; then t_pass "Client-server TLS: vsql -m require session ssl_state=$ssl"; else t_warn "TLS session could not be verified (ssl_state='${ssl:-n/a}')"; fi
    if VSQL_SSLMODE=disable vsql_t 30 "$T_HOST" "$DB_NAME" "SELECT 1;" >/dev/null 2>&1; then
      t_warn "Plain-text (non-TLS) remote login is still accepted — TLS is available but not enforced (production: add a REJECT 'HOST NO TLS' auth record)"
    else t_pass "Plain-text (non-TLS) remote logins are rejected (TLS enforced by the auth policy)"; fi
    internode_tls_checks
  else t_warn "Client-server TLS is not configured (ENABLE_DB_TLS=false) — acceptable for a lab, required in production"; fi
  local pip code; pip=$(pod_ip "${VDB}-primary-0")
  code=$(docker exec "$(cp_node)" curl -sk -o /dev/null -w '%{http_code}|%{scheme}' --max-time 15 "https://$pip:8443/v1/health" 2>/dev/null || echo "000|")
  [[ ${code#*|} == HTTPS || ${code%%|*} != 000 ]] && t_pass "HTTPS service (8443) answers over TLS (HTTP ${code%%|*})" || t_warn "HTTPS service probe: $code"
  # NetworkPolicy (temporary)
  netpol_test
  t_info "Pod Security Admission labels on namespace: $(kc get ns "$NS" -o jsonpath='{.metadata.labels}' | tr -d '{}"' | tr ',' ' ' | grep -o 'pod-security[^ ]*' | tr '\n' ' ')"
}
netpol_test() {
  local subnet; subnet=$(docker network inspect "$DOCKER_NET" -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null | tr ' ' '\n' | grep '\.' | head -n1 || true)
  cat >"$MANIFEST_DIR/intruder.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata: {name: vlab-intruder, namespace: $NS, labels: {app: vlab-intruder}}
spec:
  nodeSelector: {node-role.kubernetes.io/control-plane: ""}
  tolerations: [{key: node-role.kubernetes.io/control-plane, operator: Exists, effect: NoSchedule}]
  securityContext: {runAsUser: 5000, runAsNonRoot: true}
  containers:
  - name: client
    image: $(state_get VERTICA_IMAGE_RESOLVED)
    imagePullPolicy: IfNotPresent
    command: ["sleep", "infinity"]
    env: [{name: HOME, value: /tmp}]
    resources: {requests: {cpu: 50m, memory: 64Mi}, limits: {cpu: 500m, memory: 512Mi}}
EOF
  cat >"$MANIFEST_DIR/netpol.yaml" <<EOF
# Only pods labelled vertica-client=true may reach the SQL port 5433.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: vlab-restrict-5433, namespace: $NS}
spec:
  podSelector: {matchLabels: {vertica-lab/db: $VDB}}
  policyTypes: [Ingress]
  ingress:
  - from: [{podSelector: {matchLabels: {vertica-lab/db: $VDB}}}]          # inter-node traffic
  - from: [{namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: $OP_NS}}}]  # operator
  - from: [{podSelector: {matchLabels: {vertica-client: "true"}}}]
    ports: [{port: 5433, protocol: TCP}]
  - from: [{ipBlock: {cidr: ${subnet:-172.16.0.0/12}}}]                    # kubelet probes / NodePort
EOF
  run kc apply -f "$MANIFEST_DIR/intruder.yaml"
  kc -n "$NS" wait --for=condition=Ready pod/vlab-intruder --timeout=180s >/dev/null 2>&1 || { t_warn "Intruder pod not ready — NetworkPolicy test skipped"; return 0; }
  if VSQL_POD=vlab-intruder vsql_t 30 "$T_HOST" "$DB_NAME" "SELECT 1;" >/dev/null 2>&1; then t_info "Baseline: unlabelled pod can reach 5433 before the policy"
  else t_warn "Baseline connection from intruder failed (unexpected)"; fi
  run kc apply -f "$MANIFEST_DIR/netpol.yaml"; sleep 8
  local blocked=0 allowed=0
  VSQL_POD=vlab-intruder vsql_t 20 "$T_HOST" "$DB_NAME" "SELECT 1;" >/dev/null 2>&1 || blocked=1
  vsql_t 30 "$T_HOST" "$DB_NAME" "SELECT 1;" >/dev/null 2>&1 && allowed=1
  (( allowed )) && t_pass "NetworkPolicy: labelled client pod still connects to 5433" || t_fail "NetworkPolicy blocked the authorised client"
  (( blocked )) && t_pass "NetworkPolicy: unlabelled pod is blocked from 5433 (zero-trust ingress)" || t_warn "Unlabelled pod not blocked — CNI may not enforce NetworkPolicy"
  run --allow-fail kc -n "$NS" delete networkpolicy vlab-restrict-5433 --ignore-not-found
  run --allow-fail kc -n "$NS" delete pod vlab-intruder --ignore-not-found --wait=false
  t_info "Temporary NetworkPolicy and intruder pod removed (keeps later tests independent)"
}

t07_m2m() {
  if [[ $ENABLE_OAUTH != true || $(state_get OAUTH_INSTALLED) != 1 ]]; then t_skip "Identity provider not installed (ENABLE_OAUTH=false or installed with an older script — re-run --install)"; return 0; fi
  local q='SELECT current_user(), (SELECT ssl_state FROM sessions WHERE session_id = current_session()), (SELECT authentication_method FROM sessions WHERE session_id = current_session())'
  if keycloak_probe >/dev/null; then t_pass "Identity provider Keycloak ready (realm $IDP_REALM, OpenID Connect)"; else t_fail "Keycloak not ready"; return 0; fi
  if [[ $(sql1 "$T_HOST" "$DB_NAME" "SELECT COUNT(*) FROM client_auth WHERE auth_name='$OAUTH_RECORD' AND auth_method='OAUTH';" || true) != 1 ]]; then
    t_info "OAuth record missing (e.g. after a revive from an older catalog) — re-creating it"; configure_oauth_db || { t_fail "Could not create $OAUTH_RECORD"; return 0; }
  fi
  vsql_c "$T_HOST" "$DB_NAME" "GRANT USAGE ON SCHEMA lab TO svc_etl; GRANT SELECT ON lab.sales TO svc_etl;" >/dev/null
  # 1) the service gets a token: no user, no password — only its client credentials
  local t0 T jp
  t0=$(date +%s%N); T=$(oauth_token svc_etl); SECRET_VALUES+=("$T")
  if [[ -z $T ]]; then t_fail "svc_etl could not obtain a token from Keycloak"; return 0; fi
  metric "m2m.token_request" "$(( ($(date +%s%N) - t0) / 1000000 ))" "ms" "client_credentials grant"
  jp=$(jwt_part "$T" 1)
  t_pass "Service svc_etl obtained a signed JWT from Keycloak with grant_type=client_credentials (no human user, no password)"
  t_info "JWT claims: alg=$(jwt_part "$T" 0 | jq -r .alg) iss=<keycloak>/realms/$IDP_REALM azp=$(jq -r .azp <<<"$jp") aud=$(jq -c .aud <<<"$jp") scope=\"$(jq -r .scope <<<"$jp")\" lifetime=$(( $(jq -r .exp <<<"$jp") - $(jq -r .iat <<<"$jp") )) s"
  # 2) Vertica validates the JWT itself (signature via JWKS, issuer, audience, scope, expiry)
  local out
  t0=$(date +%s%N); out=$(oauth_login "$T" svc_etl "$q" || true)
  if [[ $out == "svc_etl|Server|OAuth" ]]; then
    metric "m2m.db_login" "$(( ($(date +%s%N) - t0) / 1000000 ))" "ms" "token validated by Vertica (JWT, JWKS keys)"
    t_pass "Vertica accepted the JWT: session user=svc_etl, TLS=Server, authentication method=OAuth"
  else t_fail "OAuth/JWT login failed: $(head -c 160 <<<"$out")"; return 0; fi
  # 3) least privilege
  out=$(oauth_login "$T" svc_etl "SELECT COUNT(*) FROM lab.sales" || true)
  [[ $out =~ ^[0-9]+$ ]] && t_pass "svc_etl can read what it was granted (lab.sales: $out rows)" || t_fail "svc_etl SELECT failed: ${out:0:120}"
  out=$(oauth_login "$T" svc_etl "INSERT INTO lab.sales SELECT * FROM lab.sales LIMIT 1" || true)
  [[ $out == *"ermission denied"* ]] && t_pass "svc_etl cannot write (INSERT denied)" || t_fail "INSERT by svc_etl was not denied: ${out:0:120}"
  out=$(oauth_login "$T" svc_etl "DROP TABLE lab.sales" || true)
  [[ $out == *"nsufficient privileges"* ]] && t_pass "svc_etl cannot drop tables (DROP denied)" || t_fail "DROP by svc_etl was not denied: ${out:0:120}"
  # 4) identity comes from the signed token, not from what the client asks for
  out=$(oauth_login "$T" dbadmin "SELECT current_user()" || true)
  [[ $out == svc_etl ]] && t_pass "Identity comes from the token: asking for 'dbadmin' still opens a svc_etl session (no privilege escalation)" || t_fail "Token login as dbadmin returned '${out:0:80}' (expected svc_etl)"
  # 5) forged tokens
  local bad forged
  bad=$(awk -F. '{s=$3; i=int(length(s)/2); c=substr(s,i,1); r=(c=="A")?"B":"A"; print $1"."$2"."substr(s,1,i-1) r substr(s,i+1)}' <<<"$T"); SECRET_VALUES+=("$bad")
  out=$(oauth_login "$bad" svc_etl "SELECT 1" || true)
  [[ $out == *"Token validation failed"* ]] && t_pass "JWT with a tampered signature is rejected" || t_fail "Tampered JWT not rejected: ${out:0:120}"
  forged=$(jq -c '.azp="dbadmin" | .client_id="dbadmin"' <<<"$jp" | base64 -w0 | tr '+/' '-_' | tr -d '=')
  forged="$(cut -d. -f1 <<<"$T").$forged.$(cut -d. -f3 <<<"$T")"; SECRET_VALUES+=("$forged")
  out=$(oauth_login "$forged" dbadmin "SELECT 1" || true)
  [[ $out == *"Token validation failed"* ]] && t_pass "JWT with a forged payload (azp=dbadmin, original signature) is rejected" || t_fail "Forged JWT not rejected: ${out:0:120}"
  # 6) wrong audience
  local O; O=$(oauth_token svc_other); SECRET_VALUES+=("$O")
  out=$(oauth_login "$O" svc_other "SELECT 1" || true)
  [[ $out == *"Token validation failed"* || $out == *"Authentication failed"* ]] && t_pass "Valid JWT without the 'vertica' audience is rejected (svc_other, aud=$(jwt_part "$O" 1 | jq -c .aud))" || t_fail "Wrong-audience JWT not rejected: ${out:0:120}"
  # 7) expiry
  local S; S=$(oauth_token svc_short); SECRET_VALUES+=("$S")
  out=$(oauth_login "$S" svc_short "SELECT current_user()" || true)
  [[ $out == svc_short ]] && t_pass "Short-lived JWT (15 s) works while valid" || t_fail "Short-lived JWT rejected while valid: ${out:0:120}"
  t_info "Waiting 20 s for the 15-second token to expire…"; sleep 20
  out=$(oauth_login "$S" svc_short "SELECT 1" || true)
  [[ $out == *"Token validation failed"* ]] && t_pass "Expired JWT is rejected" || t_fail "Expired JWT not rejected: ${out:0:120}"
  # 8) no password path for the service account
  out=$(printf 'not-a-password\n' | kc -n "$NS" exec -i "$CLIENT_POD" -c client -- sh -c 'IFS= read -r VSQL_PASSWORD; export VSQL_PASSWORD; vsql -X -At -m require -h "$1" -d "$2" -U svc_etl -c "SELECT 1" </dev/null' sh "${VDB}-primary" "$DB_NAME" 2>&1 || true)
  [[ $out == *"Authentication failed"* ]] && t_pass "Password login as svc_etl is impossible (the account has no password; only tokens work)" || t_fail "Password login as svc_etl: ${out:0:120}"
  # 9) audit trail
  local ok_n fail_n
  ok_n=$(sql1 "$T_HOST" "$DB_NAME" "SELECT COUNT(*) FROM v_monitor.user_sessions WHERE user_name='svc_etl' AND authentication_method='OAuth';" || echo 0)
  fail_n=$(sql1 "$T_HOST" "$DB_NAME" "SELECT COUNT(*) FROM v_monitor.login_failures WHERE user_name LIKE 'svc_%' AND reason ILIKE '%TOKEN VALIDATION FAILED%';" || echo 0)
  [[ ${ok_n:-0} -ge 1 && ${fail_n:-0} -ge 1 ]] && t_pass "Audit: OAuth logins in v_monitor.user_sessions ($ok_n), rejected tokens in v_monitor.login_failures ($fail_n)" || t_warn "Audit tables: user_sessions=$ok_n login_failures=$fail_n"
  # 10) signing-key rotation at the identity provider (Vertica fetches keys from JWKS)
  local kid1 kid2 T2
  kid1=$(jwt_part "$T" 0 | jq -r .kid)
  if kcadm "$(printf 'R=%q' "$IDP_REALM")" <<'KC' >>"$LOG_FILE" 2>&1
RID=$($A get "realms/$R" --fields id --format csv --noquotes)
$A create components -r "$R" -s name="vlab-rotated-$(date +%s)" -s providerId=rsa-generated -s providerType=org.keycloak.keys.KeyProvider -s parentId="$RID" \
  -s 'config.priority=["500"]' -s 'config.enabled=["true"]' -s 'config.active=["true"]' -s 'config.algorithm=["RS256"]' -s 'config.keySize=["2048"]' >/dev/null
KC
  then
    T2=$(oauth_token svc_etl); SECRET_VALUES+=("$T2"); kid2=$(jwt_part "$T2" 0 | jq -r .kid)
    out=$(oauth_login "$T2" svc_etl "SELECT current_user()" || true)
    if [[ -n $kid2 && $kid2 != "$kid1" && $out == svc_etl ]]; then t_pass "Signing-key rotation: a token signed with the NEW key (kid ${kid2:0:8}…) is accepted without any change in Vertica (keys fetched from JWKS)"
    else t_fail "Key rotation check: kid ${kid1:0:8}->${kid2:0:8}, login='${out:0:80}'"; fi
  else t_warn "Could not rotate the Keycloak signing key (details in the log)"; fi
  vsql_show "$T_HOST" "$DB_NAME" "Audit: OAuth sessions and rejected tokens" \
    "SELECT user_name, authentication_method, COUNT(*) AS sessions FROM v_monitor.user_sessions WHERE user_name LIKE 'svc_%' GROUP BY 1,2 UNION ALL SELECT user_name, 'rejected: '||LOWER(reason), COUNT(*) FROM v_monitor.login_failures WHERE user_name LIKE 'svc_%' GROUP BY 1,2 ORDER BY 1,2;" || true
}
t08_isolation() {
  vsql_c "$T_HOST" "$DB_NAME" "DROP USER IF EXISTS lab_etl CASCADE; DROP USER IF EXISTS lab_bi CASCADE;" >/dev/null 2>&1 || true
  vsql_c "$T_HOST" "$DB_NAME" "DROP RESOURCE POOL lab_etl_pool;" >/dev/null 2>&1 || true
  vsql_c "$T_HOST" "$DB_NAME" "DROP RESOURCE POOL lab_bi_pool;" >/dev/null 2>&1 || true
  vsql_show "$T_HOST" "$DB_NAME" "Create isolated resource pools + users" "
CREATE RESOURCE POOL lab_etl_pool MEMORYSIZE '0%' MAXMEMORYSIZE '30%' PLANNEDCONCURRENCY 2 MAXCONCURRENCY 2 PRIORITY -10 QUEUETIMEOUT 600;
CREATE RESOURCE POOL lab_bi_pool MEMORYSIZE '10%' MAXMEMORYSIZE '40%' PLANNEDCONCURRENCY 4 MAXCONCURRENCY 8 PRIORITY 50 RUNTIMECAP '5 minutes';
CREATE USER lab_etl IDENTIFIED BY '$LAB_USER_PASSWORD'; CREATE USER lab_bi IDENTIFIED BY '$LAB_USER_PASSWORD';
GRANT USAGE ON RESOURCE POOL lab_etl_pool TO lab_etl; GRANT USAGE ON RESOURCE POOL lab_bi_pool TO lab_bi;
ALTER USER lab_etl RESOURCE POOL lab_etl_pool; ALTER USER lab_bi RESOURCE POOL lab_bi_pool;
GRANT USAGE ON SCHEMA lab TO lab_etl, lab_bi; GRANT SELECT ON ALL TABLES IN SCHEMA lab TO lab_etl, lab_bi;
SELECT name, maxmemorysize, maxconcurrency, priority FROM resource_pools WHERE name LIKE 'lab_%';" >/dev/null \
    || { t_fail "Could not create resource pools"; return 0; }
  t_pass "Resource pools lab_etl_pool (capped) and lab_bi_pool (high priority) created"
  local tag; tag="i$(date +%H%M%S)"
  local bq="SELECT /*+LABEL(lab_iso_bi_${tag}_base)*/ region, COUNT(*) FROM lab.sales s JOIN lab.customers c ON c.customer_id=s.customer_id WHERE s.sale_id % 50 = 1 GROUP BY 1;"
  local i; for i in 1 2 3; do vsql_as 120 raw lab_bi "$LAB_USER_PASSWORD" "$T_HOST" "$DB_NAME" "$bq" >/dev/null; done
  t_info "Starting ETL storm: 12 heavy window queries as lab_etl (MAXCONCURRENCY 2 => admission queueing)"
  printf '%s\n' "$LAB_USER_PASSWORD" | timeout 900 "${KC[@]}" exec -i -n "$NS" "$CLIENT_POD" -c client -- sh -c '
    h=$1; d=$2; t=$3; IFS= read -r VSQL_PASSWORD; export VSQL_PASSWORD; i=0
    while [ $i -lt 12 ]; do /opt/vertica/bin/vsql -m prefer -X -q -At -h "$h" -d "$d" -U lab_etl -c "SELECT /*+LABEL(lab_iso_etl_${t})*/ SUM(x) FROM (SELECT ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY sale_ts, sale_id) x FROM lab.sales) q" >/dev/null 2>&1 & i=$((i+1)); done; wait' \
    sh "$T_HOST" "$DB_NAME" "$tag" >/dev/null 2>&1 &
  local etl_pid=$!; BG_PIDS+=("$etl_pid")
  sleep 4
  local maxq=0 q
  for i in $(seq 1 10); do
    q=$(sql1 "$T_HOST" "$DB_NAME" "SELECT COUNT(*) FROM v_monitor.resource_queues WHERE pool_name='lab_etl_pool';" 2>/dev/null || echo 0)
    [[ $q =~ ^[0-9]+$ ]] && (( q > maxq )) && maxq=$q
    vsql_as 120 raw lab_bi "$LAB_USER_PASSWORD" "$T_HOST" "$DB_NAME" "${bq//_base/_load}" >/dev/null 2>&1 || true
  done
  wait "$etl_pid" 2>/dev/null || true
  sleep 2
  metric "isolation.etl_max_queued" "$maxq" "queries" "admission control in lab_etl_pool"
  (( maxq > 0 )) && t_pass "Admission control: up to $maxq ETL queries queued while BI kept running" || t_info "No ETL queueing observed (queries finished quickly)"
  local pools; pools=$(vsql_c "$T_HOST" "$DB_NAME" "SELECT DISTINCT qr.request_label, ra.pool_name FROM v_monitor.query_requests qr JOIN v_monitor.resource_acquisitions ra ON ra.transaction_id=qr.transaction_id AND ra.statement_id=qr.statement_id WHERE qr.request_label LIKE 'lab_iso_%_${tag}%';" || true)
  grep -q 'lab_iso_bi.*|lab_bi_pool' <<<"$pools" && t_pass "BI queries executed in lab_bi_pool" || t_warn "BI pool routing not confirmed: ${pools//$'\n'/; }"
  grep -q 'lab_iso_etl.*|lab_etl_pool' <<<"$pools" && t_pass "ETL queries executed in lab_etl_pool" || t_warn "ETL pool routing not confirmed"
  local base load
  base=$(sql1 "$T_HOST" "$DB_NAME" "SELECT ROUND(AVG(request_duration_ms)) FROM v_monitor.query_requests WHERE request_label='lab_iso_bi_${tag}_base' AND success;")
  load=$(sql1 "$T_HOST" "$DB_NAME" "SELECT ROUND(AVG(request_duration_ms)) FROM v_monitor.query_requests WHERE request_label='lab_iso_bi_${tag}_load' AND success;")
  metric "isolation.bi_latency_idle" "${base:-n/a}" "ms"
  metric "isolation.bi_latency_during_etl" "${load:-n/a}" "ms" "same physical CPUs on one workstation"
  t_info "Subcluster-level isolation (separate compute per workload) is exercised in the 'scaling' group."
}

t09_reconcile() {
  local svc="${VDB}-primary" uid1 t0
  uid1=$(kc -n "$NS" get svc "$svc" -o jsonpath='{.metadata.uid}')
  t_info "Drift #1: deleting operator-managed Service $svc"
  run kc -n "$NS" delete svc "$svc" --wait=false
  t0=$(date +%s)
  probe_svc() { local u; u=$(kc -n "$NS" get svc "$1" -o jsonpath='{.metadata.uid}' 2>/dev/null || true); printf 'service uid %s' "${u:-absent}"; [[ -n $u && $u != "$2" ]]; }
  if wait_until "Operator recreates Service $svc" 300 3 probe_svc "$svc" "$uid1"; then
    metric "reconcile.service_recreate" "$(( $(date +%s) - t0 ))" "s"; t_pass "Deleted Service recreated by the operator"
  else t_fail "Service not recreated"; fi
  t_info "Drift #2: manually scaling StatefulSet ${VDB}-primary to 2 replicas (desired = 3 in the CR)"
  run kc -n "$NS" scale sts "${VDB}-primary" --replicas=2
  t0=$(date +%s)
  probe_sts() { local r; r=$(kc -n "$NS" get sts "$1" -o jsonpath='{.spec.replicas}' 2>/dev/null); printf 'sts replicas=%s' "$r"; [[ $r == "$2" ]]; }
  if wait_until "Operator restores StatefulSet replicas to 3" 300 3 probe_sts "${VDB}-primary" 3; then
    metric "reconcile.sts_drift_fix" "$(( $(date +%s) - t0 ))" "s"; t_pass "StatefulSet drift corrected to the CR's desired state"
  else t_fail "StatefulSet drift not corrected"; fi
  if wait_db_ready "$VDB" "$DB_NAME" 3 "$RECOVERY_TIMEOUT" "Database back to 3/3 nodes UP"; then t_pass "All Vertica nodes UP after drift correction"; else t_fail "DB did not return to 3/3"; fi
  t_info "Drift #3: deleting the operator pod itself (controller outage)"
  local op; op=$(kc -n "$OP_NS" get pods -o name | grep -i verticadb-operator | head -n1 || true)
  if [[ -n $op ]]; then
    run kc -n "$OP_NS" delete "$op" --wait=false
    local up; up=$(up_count_via "$T_HOST" "$DB_NAME" || true)
    [[ $up == 3 ]] && t_pass "Database unaffected while the operator is down (3/3 UP)" || t_warn "DB nodes UP during operator restart: ${up:-?}"
    wait_until "Operator pod rescheduled and available" 300 5 operator_probe && t_pass "Operator Deployment self-healed" || t_fail "Operator not back"
    uid1=$(kc -n "$NS" get svc "$svc" -o jsonpath='{.metadata.uid}')
    run kc -n "$NS" delete svc "$svc" --wait=false
    wait_until "New operator instance resumes reconciliation" 300 3 probe_svc "$svc" "$uid1" && t_pass "Reconciliation resumed after operator restart" || t_fail "Reconciliation did not resume"
  fi
  t_info "Admission webhook: attempting invalid changes (server-side dry-run, nothing is persisted)"
  if kc -n "$NS" patch vdb "$VDB" --type=merge -p '{"spec":{"shardCount":12}}' --dry-run=server >>"$LOG_FILE" 2>&1; then
    t_warn "shardCount change was accepted by the webhook (dry-run)"; else t_pass "Webhook rejects changing immutable shardCount"; fi
  if kc -n "$NS" patch vdb "$VDB" --type=merge -p '{"spec":{"dbName":"otherdb"}}' --dry-run=server >>"$LOG_FILE" 2>&1; then
    t_warn "dbName change accepted (dry-run)"; else t_pass "Webhook rejects renaming the database"; fi
  if kc -n "$NS" patch vdb "$VDB" --type=json -p '[{"op":"replace","path":"/spec/subclusters/0/size","value":2}]' --dry-run=server >>"$LOG_FILE" 2>&1; then
    t_warn "Shrinking K-safe primary to 2 accepted (dry-run)"; else t_pass "Webhook rejects shrinking the K-safe primary subcluster below 3"; fi
}

# Vertica runs as PID 1 of the server container (--no-daemon). The kernel ignores SIGKILL sent to a
# namespace's PID 1 from inside that namespace, so the crash is injected from the kind node's PID
# namespace (exactly what an OOM-kill or a segfault looks like to Kubernetes: the container dies).
kill_vertica_proc() { # pod vnode
  local node; node=$(pod_node "$1")
  if [[ -z $node ]]; then echo "killed=0 (node of $1 unknown)"; return 0; fi
  docker exec "$node" sh -c '
    n=0; for d in /proc/[0-9]*; do
      c=$(tr "\0" " " < "$d/cmdline" 2>/dev/null) || continue
      case "$c" in "/opt/vertica/bin/vertica -D "*" -n $1 "*) echo "SIGKILL vertica pid ${d#/proc/} (node-level pid)"; kill -9 "${d#/proc/}" && n=$((n+1));; esac
    done; echo "killed=$n"' sh "$2"
}
t10_selfheal_process() {
  local victim="${VDB}-primary-1" surv vnode sip t0 out
  surv=$(other_ready_pod "$VDB" "$victim"); sip=$(pod_ip "$surv"); vnode=$(vnode_of_pod "$victim")
  t_info "Victim: pod $victim (Vertica node $vnode); observer: $surv"
  local rc0; rc0=$(kc -n "$NS" get pod "$victim" -o jsonpath='{.status.containerStatuses[?(@.name=="server")].restartCount}' 2>/dev/null || echo 0)
  start_load selfheal_process "$LOAD_SECONDS" "$T_HOST" "$DB_NAME"
  sleep 5
  out=$(kill_vertica_proc "$victim" "$vnode" 2>&1 || true); t_info "Simulated crash: $(tr '\n' ' ' <<<"$out")"
  if ! grep -q 'killed=[1-9]' <<<"$out"; then t_fail "Vertica process for $vnode not found on $(pod_node "$victim") — crash not injected"; finish_load selfheal_process; return 0; fi
  t0=$(date +%s)
  local down_seen=0
  if wait_until "Cluster detects node failure" 60 1 probe_node_state "$sip" "$DB_NAME" "$vnode" notUP; then
    down_seen=1; metric "selfheal.process.detect" "$(( $(date +%s) - t0 ))" "s" "crash -> node DOWN in catalog"
  else t_info "DOWN state not observed (restart was faster than the 1s probe)"; fi
  local up; up=$(up_count_via "$sip" "$DB_NAME" || true)
  if (( down_seen )); then
    if [[ ${up:-0} -ge 2 ]]; then t_pass "Database stayed UP with K-safety while a node was down (${up}/3 UP)"; else t_fail "Quorum issue: ${up:-?}/3 UP"; fi
  fi
  if wait_until "Operator restarts Vertica on $victim (node rejoins)" "$RECOVERY_TIMEOUT" 3 probe_node_state "$sip" "$DB_NAME" "$vnode" UP; then
    metric "selfheal.process.recovery" "$(( $(date +%s) - t0 ))" "s" "crash -> node UP"; t_pass "Crashed Vertica process automatically restarted and rejoined"
  else t_fail "Node did not recover"; fi
  local rc1; rc1=$(kc -n "$NS" get pod "$victim" -o jsonpath='{.status.containerStatuses[?(@.name=="server")].restartCount}' 2>/dev/null || echo 0)
  t_info "Server container restartCount $rc0 -> $rc1 (kubelet restarted the crashed container)"
  finish_load selfheal_process
  t_info "During a node failure Vertica briefly pauses queries on the surviving nodes while it re-forms the cluster (spread membership change) — that pause is the outage you see."
  assert_client_recovered "process crash"
}
t11_selfheal_pod() {
  local victim="${VDB}-primary-2" surv sip vnode uid0 pv0 t0 before
  surv=$(other_ready_pod "$VDB" "$victim"); sip=$(pod_ip "$surv"); vnode=$(vnode_of_pod "$victim")
  uid0=$(pod_uid "$victim"); pv0=$(kc -n "$NS" get pvc "local-data-$victim" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)
  vsql_c "$T_HOST" "$DB_NAME" "CREATE TABLE IF NOT EXISTS lab.heartbeat (id IDENTITY, ts TIMESTAMP DEFAULT NOW(), note VARCHAR(40)); INSERT INTO lab.heartbeat (note) VALUES ('before-pod-delete'); COMMIT;" >/dev/null
  before=$(sql1 "$T_HOST" "$DB_NAME" "SELECT COUNT(*) FROM lab.sales;")
  start_load selfheal_pod "$LOAD_SECONDS" "$T_HOST" "$DB_NAME"; sleep 5
  t_info "Deleting pod $victim (simulates pod eviction / container runtime failure)"
  run kc -n "$NS" delete pod "$victim" --wait=false
  t0=$(date +%s)
  probe_new_pod() { local u r; u=$(pod_uid "$1"); r=$(kc -n "$NS" get pod "$1" -o jsonpath='{.status.phase}' 2>/dev/null); printf 'pod %s phase=%s%s' "$1" "${r:-absent}" "$(load_status_text)"; [[ -n $u && $u != "$2" && $r == Running ]]; }
  if wait_until "StatefulSet recreates $victim" 180 2 probe_new_pod "$victim" "$uid0"; then t_pass "Pod recreated by StatefulSet controller"; else t_fail "Pod $victim not recreated"; fi
  if wait_until "Vertica node $vnode rejoins cluster" "$RECOVERY_TIMEOUT" 3 probe_node_state "$sip" "$DB_NAME" "$vnode" UP; then
    metric "selfheal.pod.recovery" "$(( $(date +%s) - t0 ))" "s" "delete -> node UP"; t_pass "Deleted pod recovered and Vertica node rejoined automatically"
  else t_fail "Node did not rejoin"; fi
  local pv1; pv1=$(kc -n "$NS" get pvc "local-data-$victim" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)
  [[ -n $pv0 && $pv0 == "$pv1" ]] && t_pass "Same PersistentVolume re-attached ($pv1) — catalog/depot persisted" || t_warn "PV changed: $pv0 -> $pv1"
  local after; after=$(sql1 "$T_HOST" "$DB_NAME" "SELECT COUNT(*) FROM lab.sales;")
  [[ $after == "$before" ]] && t_pass "No data loss: lab.sales still $after rows" || t_fail "Row count changed $before -> $after"
  finish_load selfheal_pod
  assert_client_recovered "pod deletion"
}

t12_nodefail() {
  local avoid=() w victim_node="" victim_pod="" p
  avoid+=("$(kc -n "$MINIO_NS" get pods -l app=minio -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)")
  avoid+=("$(pod_node "$CLIENT_POD" || true)")
  avoid+=("$(kc -n "$OP_NS" get pods -o json 2>/dev/null | jq -r '[.items[] | select(.metadata.name|test("verticadb-operator"))][0].spec.nodeName // empty' || true)")
  for p in "${VDB}-primary-2" "${VDB}-primary-1" "${VDB}-primary-0"; do
    w=$(pod_node "$p"); [[ -z $w || $w == *control-plane ]] && continue
    local bad=0 a; for a in "${avoid[@]}"; do if [[ $a == "$w" ]]; then bad=1; fi; done
    local cnt; cnt=$(vdb_pods_json "$VDB" | jq --arg n "$w" '[.[] | select(.spec.nodeName==$n)] | length')
    (( bad == 0 && cnt == 1 )) && { victim_node=$w; victim_pod=$p; break; }
  done
  if [[ -z $victim_node ]]; then t_skip "No worker hosts exactly one Vertica pod and no infra pods — cannot run safely"; return 0; fi
  local surv sip vnode t0 tdown
  surv=$(other_ready_pod "$VDB" "$victim_pod"); sip=$(pod_ip "$surv"); vnode=$(vnode_of_pod "$victim_pod")
  t_info "Victim worker: $victim_node (hosts $victim_pod = $vnode). Failure mode: 'docker pause' freezes the whole node"
  t_info "(kubelet, containerd and Vertica stop responding — like a hung server or a network partition) for ${NODE_FAIL_SECONDS}s"
  # the client window must outlast the freeze, or the application's recovery cannot be observed
  local nf_load=$LOAD_SECONDS; (( nf_load < NODE_FAIL_SECONDS + 45 )) && nf_load=$(( NODE_FAIL_SECONDS + 45 ))
  start_load nodefail "$nf_load" "$T_HOST" "$DB_NAME"; sleep 5
  run docker pause "$victim_node"
  t0=$(date +%s)
  wait_until "Vertica detects loss of $vnode" "$NODE_FAIL_SECONDS" 2 probe_node_state "$sip" "$DB_NAME" "$vnode" notUP \
    && { tdown=$(( $(date +%s) - t0 )); metric "nodefail.vertica_detect" "$tdown" "s"; }
  probe_k8s_notready() { local s; s=$(kc get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null); printf 'node %s Ready=%s%s' "$1" "$s" "$(load_status_text)"; [[ $s != True ]]; }
  local kleft=$(( NODE_FAIL_SECONDS - ( $(date +%s) - t0 ) )); (( kleft < 10 )) && kleft=10
  wait_until "Kubernetes marks $victim_node NotReady" "$kleft" 3 probe_k8s_notready "$victim_node" \
    && metric "nodefail.k8s_detect" "$(( $(date +%s) - t0 ))" "s" "node-monitor-grace-period" \
    || t_info "Kubernetes did not mark the node NotReady within the ${NODE_FAIL_SECONDS}s freeze (default grace period ~40-50s) — Vertica detected it anyway"
  if vsql_t 60 "$sip" "$DB_NAME" "INSERT INTO lab.heartbeat (note) VALUES ('during-node-failure'); COMMIT;" >/dev/null 2>&1 \
     && [[ $(sql1 "$sip" "$DB_NAME" "SELECT COUNT(*) FROM lab.heartbeat WHERE note='during-node-failure';") -ge 1 ]]; then
    t_pass "Reads AND writes succeed with 1 of 3 nodes failed (K-safety 1)"
  else t_fail "Database not writable during node failure"; fi
  local remain=$(( NODE_FAIL_SECONDS - ( $(date +%s) - t0 ) ))
  if (( remain > 0 )); then
    probe_sleep() { local left=$(( $1 - $(date +%s) )); printf 'node stays failed, %ss left%s' "$left" "$(load_status_text)"; (( left <= 0 )); }
    wait_until "Keeping $victim_node failed" $(( remain + 5 )) 3 probe_sleep $(( $(date +%s) + remain )) || true
  fi
  run docker unpause "$victim_node"
  local t1; t1=$(date +%s)
  probe_k8s_ready() { local s; s=$(kc get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null); printf 'node %s Ready=%s' "$1" "$s"; [[ $s == True ]]; }
  wait_until "Worker $victim_node Ready again" 180 3 probe_k8s_ready "$victim_node" || t_fail "Node did not return to Ready"
  if wait_until "Operator restores $vnode (3/3 UP)" "$RECOVERY_TIMEOUT" 3 probe_db_up_n "$sip" "$DB_NAME" 3; then
    metric "nodefail.recovery_after_restore" "$(( $(date +%s) - t1 ))" "s" "node back -> 3/3 UP"; t_pass "Node failure fully recovered without manual intervention"
  else t_fail "Cluster did not return to 3/3 UP"; fi
  finish_load nodefail
  assert_client_recovered "node freeze"
  t_info "Why availability is lower here: the Service keeps sending some new connections to the frozen pod until Kubernetes marks the node NotReady (~40-50s); each such query waits for its 8s timeout. Production clients add connection load balancing + retry."
  t_info "Production note: a permanently lost host needs pod rescheduling to another machine, which requires network-attached storage (see PROD-ONLY list)."
}

vrpq_probe() { # name
  local st; st=$(kc -n "$NS" get vrpq "$1" -o jsonpath='{.status.state}' 2>/dev/null || true)
  printf 'state: %s' "${st:-pending}"
  [[ $st == "Query successful" ]] && return 0
  [[ $st == *[Ff]ail* ]] && return 2
  return 1
}
wait_vrpq() { # name desc
  local rc=0; WATCH_VDB=$1; WAIT_HOOK=show_vdb_events
  wait_until "$2" 900 5 vrpq_probe "$1" || rc=$?
  WAIT_HOOK=""; WATCH_VDB=""
  return $rc
}
t13_backup() {
  local tag; tag=$(date +%H%M%S)
  vsql_show "$T_HOST" "$DB_NAME" "Prepare backup test tables" "
DROP TABLE IF EXISTS lab.bk_orders CASCADE; DROP TABLE IF EXISTS lab.bk_audit CASCADE; DROP TABLE IF EXISTS lab.bk_orders_ext CASCADE;
CREATE TABLE lab.bk_orders (order_id INT, phase VARCHAR(10), amount NUMERIC(12,2));
INSERT INTO lab.bk_orders SELECT n, 'before', (n % 500)::NUMERIC(12,2) FROM lab.nums;
CREATE TABLE lab.bk_audit (id INT, event VARCHAR(40));
INSERT INTO lab.bk_audit SELECT n, 'audit-event-'||n FROM lab.nums WHERE n < 100; COMMIT;
SELECT (SELECT COUNT(*) FROM lab.bk_orders) AS bk_orders, (SELECT COUNT(*) FROM lab.bk_audit) AS bk_audit;" >/dev/null || { t_fail "Could not prepare tables"; return 0; }
  local sales_rows; sales_rows=$(sql1 "$T_HOST" "$DB_NAME" "SELECT COUNT(*) FROM lab.sales;")
  # 1) operator-driven restore point
  cat >"$MANIFEST_DIR/vrpq-save.yaml" <<EOF
apiVersion: vertica.com/v1
kind: VerticaRestorePointsQuery
metadata: {name: vlab-save-$tag, namespace: $NS}
spec:
  verticaDBName: $VDB
  queryType: SaveRestorePoint
  saveOptions: {archiveName: $RP_ARCHIVE, numRestorePoints: 5}
EOF
  run kc apply -f "$MANIFEST_DIR/vrpq-save.yaml"
  local rp_ok=0 t0; t0=$(date +%s)
  if wait_vrpq "vlab-save-$tag" "Operator saves restore point to archive $RP_ARCHIVE"; then
    rp_ok=1; metric "backup.save_restore_point" "$(( $(date +%s) - t0 ))" "s"; t_pass "Restore point saved via VerticaRestorePointsQuery (SaveRestorePoint)"
  else
    t_warn "VRPQ SaveRestorePoint failed — falling back to SQL"
    if vsql_c "$T_HOST" "$DB_NAME" "CREATE ARCHIVE IF NOT EXISTS $RP_ARCHIVE LIMIT 5; SAVE RESTORE POINT TO ARCHIVE $RP_ARCHIVE;" >/dev/null; then rp_ok=1; t_pass "Restore point saved with SQL (SAVE RESTORE POINT TO ARCHIVE)"; else t_fail "Could not save a restore point"; fi
  fi
  cat >"$MANIFEST_DIR/vrpq-show.yaml" <<EOF
apiVersion: vertica.com/v1
kind: VerticaRestorePointsQuery
metadata: {name: vlab-show-$tag, namespace: $NS}
spec:
  verticaDBName: $VDB
  queryType: ShowRestorePoints
  filterOptions: {archiveName: $RP_ARCHIVE}
EOF
  run --allow-fail kc apply -f "$MANIFEST_DIR/vrpq-show.yaml"
  if wait_vrpq "vlab-show-$tag" "List restore points"; then
    kc -n "$NS" get vrpq "vlab-show-$tag" -o json | jq -r '.status.restorePoints[]? | "index=\(.index) id=\(.id) ts=\(.timestamp)"' | head -n 5 | while IFS= read -r l; do detail "$l"; done
  fi
  # 2) simulate incidents after the backup
  vsql_c "$T_HOST" "$DB_NAME" "INSERT INTO lab.bk_orders SELECT n+100000, 'after', 1 FROM lab.nums WHERE n < 5000; COMMIT; DROP TABLE lab.bk_audit CASCADE;" >/dev/null
  t_info "Incident simulated: 5,000 unwanted rows inserted into bk_orders and table bk_audit DROPPED"
  # 3) logical backup to object storage (EXPORT TO PARQUET)
  local edir="s3://$BUCKET/exports/$tag/bk_orders" pq
  pq=$(sql1 "$T_HOST" "$DB_NAME" "SELECT COUNT(*) FROM user_functions WHERE function_name ILIKE 'ParquetExport';" || echo 0)
  if [[ $pq == 0 ]]; then
    t_skip "Logical backup (EXPORT TO PARQUET) skipped: the ParquetExport package is not part of the '-minimal' Vertica image (use the full image to enable it)"
  elif vsql_c "$T_HOST" "$DB_NAME" "EXPORT TO PARQUET(directory='$edir') AS SELECT * FROM lab.bk_orders;" >/dev/null 2>&1 \
     && vsql_c "$T_HOST" "$DB_NAME" "CREATE EXTERNAL TABLE lab.bk_orders_ext (order_id INT, phase VARCHAR(10), amount NUMERIC(12,2)) AS COPY FROM '$edir/*.parquet' PARQUET;" >/dev/null 2>&1; then
    local ec; ec=$(sql1 "$T_HOST" "$DB_NAME" "SELECT COUNT(*) FROM lab.bk_orders_ext;")
    [[ $ec == 15000 ]] && t_pass "Logical backup: EXPORT TO PARQUET -> S3 and read back via external table ($ec rows)" || t_fail "Parquet round-trip returned $ec rows (expected 15000)"
  else t_warn "EXPORT TO PARQUET to communal bucket failed (S3 parameters may differ)"; fi
  (( rp_ok )) || { t_fail "No restore point — skipping restore tests"; return 0; }
  # 4) object-level restore (single table) from the archive
  cat >"$MANIFEST_DIR/vrpq-restore.yaml" <<EOF
apiVersion: vertica.com/v1
kind: VerticaRestorePointsQuery
metadata: {name: vlab-restore-$tag, namespace: $NS}
spec:
  verticaDBName: $VDB
  queryType: Restore
  restoreOptions:
    archiveName: $RP_ARCHIVE
    objects: "include table lab.bk_audit"
    mode: CREATE_OR_REPLACE
    restorePoint: "1"
    dryRun: false
EOF
  run --allow-fail kc apply -f "$MANIFEST_DIR/vrpq-restore.yaml"
  t0=$(date +%s)
  if wait_vrpq "vlab-restore-$tag" "Operator restores dropped table lab.bk_audit from restore point"; then
    local ac; ac=$(sql1 "$T_HOST" "$DB_NAME" "SELECT COUNT(*) FROM lab.bk_audit;" || echo 0)
    metric "backup.table_restore" "$(( $(date +%s) - t0 ))" "s"
    [[ $ac == 100 ]] && t_pass "Object-level restore: dropped table recovered with 100 rows" || t_fail "bk_audit has ${ac:-0} rows after restore"
  else t_warn "Object-level restore via VRPQ not completed (requires server 26.2+)"; fi
  # 5) full disaster recovery: delete the whole database deployment, revive from the restore point
  t_info "DISASTER RECOVERY: shut down + DELETE VerticaDB '$VDB' (pods + PVCs), then revive from communal storage at restore point #1"
  local vj hsec csec isec; vj=$(kc -n "$NS" get vdb "$VDB" -o json); printf '%s\n' "$vj" >"$RUN_DIR/vdb-before-revive.json"
  hsec=$(jq -r '.spec.httpsNMATLS.secret // empty' <<<"$vj"); csec=$(jq -r '.spec.clientServerTLS.secret // empty' <<<"$vj")
  isec=$(jq -r '.spec.interNodeTLS.secret // empty' <<<"$vj")
  [[ -n $hsec ]] && t_info "Preserving TLS secrets for revive (docs: the catalog expects the original certificates): httpsNMATLS=$hsec clientServerTLS=${csec:-n/a} interNodeTLS=${isec:-n/a}"
  local tdr; tdr=$(date +%s)
  run --allow-fail kc -n "$NS" patch vdb "$VDB" --type=merge -p '{"spec":{"shutdown":true}}'
  probe_pods_gone() { local n; n=$(vdb_pods_json "$1" | jq length); printf '%s pods remaining' "$n"; [[ $n == 0 ]]; }
  wait_until "Graceful shutdown (operator drains + stops Vertica, removes pods)" 900 5 probe_pods_gone "$VDB" || t_warn "Graceful shutdown incomplete — deleting anyway"
  run kc -n "$NS" delete vdb "$VDB" --wait=true --timeout=600s
  probe_pvc_gone() { local n; n=$(kc -n "$NS" get pvc -o name 2>/dev/null | grep -c "local-data-$1-" || true); printf '%s PVCs remaining' "$n"; [[ $n == 0 ]]; }
  if ! wait_until "Operator deletes the database PVCs" 300 5 probe_pvc_gone "$VDB"; then
    kc -n "$NS" get pvc -o name | grep "local-data-$VDB-" | xargs -r "${KC[@]}" -n "$NS" delete --wait=false >/dev/null 2>&1 || true
  fi
  t_pass "Database deployment destroyed: no pods, no local volumes — only communal storage remains"
  render_vdb "$VDB" "$DB_NAME" "$(state_get COMMUNAL_PATH)" Revive 3 "$(state_get VDB_MEM_GB)" "$(state_get VDB_CPU_CORES)" NodePort "$NODEPORT_PRIMARY" false 6 \
    "$RP_ARCHIVE" "$hsec" "$csec" "$isec" >"$MANIFEST_DIR/vdb-revive.yaml"
  apply_with_retry "$MANIFEST_DIR/vdb-revive.yaml" 6 || { t_fail "Revive CR rejected"; recover_ha_db; return 0; }
  local trev; trev=$(date +%s)
  if wait_db_ready "$VDB" "$DB_NAME" 3 "$DB_CREATE_TIMEOUT" "Revive from restore point (initPolicy: Revive)"; then
    metric "backup.revive_rto" "$(( $(date +%s) - trev ))" "s" "revive -> 3/3 UP"
    metric "backup.total_outage" "$(( $(date +%s) - tdr ))" "s" "shutdown+delete+revive"
    t_pass "Database revived from communal storage on brand-new pods/volumes"
    local bo sr; bo=$(sql1 "$T_HOST" "$DB_NAME" "SELECT COUNT(*) FROM lab.bk_orders;" || echo "?")
    sr=$(sql1 "$T_HOST" "$DB_NAME" "SELECT COUNT(*) FROM lab.sales;" || echo "?")
    [[ $bo == 10000 ]] && t_pass "Point-in-time restore: bk_orders = 10,000 (the 5,000 post-backup rows are gone)" || t_fail "bk_orders = $bo (expected 10000)"
    [[ $sr == "$sales_rows" ]] && t_pass "Fact table intact after DR: lab.sales = $sr" || t_fail "lab.sales = $sr (expected $sales_rows)"
  else
    t_fail "Revive from restore point failed"; recover_ha_db
  fi
  run --allow-fail kc -n "$NS" delete vrpq "vlab-save-$tag" "vlab-show-$tag" "vlab-restore-$tag" --ignore-not-found --wait=false
}
recover_ha_db() {
  warn "Attempting automatic recovery: revive latest committed state (no restore point)"
  run --allow-fail kc -n "$NS" delete vdb "$VDB" --ignore-not-found --wait=true --timeout=600s
  render_vdb "$VDB" "$DB_NAME" "$(state_get COMMUNAL_PATH)" Revive 3 "$(state_get VDB_MEM_GB)" "$(state_get VDB_CPU_CORES)" NodePort "$NODEPORT_PRIMARY" false 6 \
    "" "" "" >"$MANIFEST_DIR/vdb-revive-latest.yaml"
  apply_with_retry "$MANIFEST_DIR/vdb-revive-latest.yaml" 6 && wait_db_ready "$VDB" "$DB_NAME" 3 "$DB_CREATE_TIMEOUT" "Recovery revive" \
    && ok "HA database recovered" || err "Recovery failed — run: sudo $SCRIPT_PATH --status ; consider --cleanup and --install"
}

sc_index() { kc -n "$NS" get vdb "$1" -o json | jq --arg n "$2" '.spec.subclusters | map(.name) | index($n)'; }
probe_sc_up() { # host db sc expected total_expected
  local a t; a=$(vsql_t 25 "$1" "$2" "SELECT COUNT(*) FROM v_catalog.subclusters s JOIN nodes n ON n.node_name=s.node_name WHERE s.subcluster_name='$3' AND n.node_state='UP';" 2>/dev/null | tr -d '[:space:]' || true)
  t=$(vsql_t 25 "$1" "$2" "SELECT COUNT(*) FROM nodes;" 2>/dev/null | tr -d '[:space:]' || true)
  printf 'subcluster %s UP %s/%s | catalog nodes %s/%s' "$3" "${a:-?}" "$4" "${t:-?}" "$5"
  [[ $a == "$4" && $t == "$5" ]]
}
t14_scaling() {
  local maxn; maxn=$(state_get MAX_NODES 3)
  local svdb sdb base host mem cpu svctype np
  if (( maxn >= 5 )); then
    svdb=$VDB; sdb=$DB_NAME; base=3; host="${VDB}-primary"; mem=$(state_get ELASTIC_MEM_GB 2); cpu=$(state_get ELASTIC_CPU_CORES 1)
    svctype=NodePort; np=$NODEPORT_SECONDARY
    local need=$(( 2 * mem + HOST_RESERVE_GB )) avail=$(( $(mem_kb MemAvailable) / 1048576 ))
    if (( avail < need )); then t_skip "Not enough free RAM for 2 secondary pods (${avail} GB available, ${need} GB needed)"; return 0; fi
    t_info "Licensed node capacity $maxn: scaling the main HA database by adding a secondary subcluster"
  else
    svdb=$VDBE; sdb=$DBE_NAME; base=1; host="${VDBE}-primary"; mem=$(state_get ELASTIC_MEM_GB 2); cpu=$(state_get ELASTIC_CPU_CORES 1)
    svctype=ClusterIP; np=""
    local need=$(( 3 * mem + HOST_RESERVE_GB )) avail=$(( $(mem_kb MemAvailable) / 1048576 ))
    if (( avail < need )); then t_skip "Not enough free RAM for the elastic DB (${avail} GB available, ${need} GB needed)"; return 0; fi
    t_info "Trial limit (3 nodes/DB): creating a separate elastic DB '$sdb' (1 primary) to scale a secondary subcluster 0->1->2->1->0"
    kc -n "$NS" delete vdb "$VDBE" --ignore-not-found --wait=true --timeout=300s >/dev/null 2>&1 || true
    local epath="s3://$BUCKET/$DBE_NAME-$(date +%Y%m%d%H%M%S)"; state_set ELASTIC_PATH "$epath"
    render_vdb "$VDBE" "$DBE_NAME" "$epath" "$DB_INIT_POLICY" 1 "$mem" "$cpu" ClusterIP "" true 3 >"$MANIFEST_DIR/vdbe.yaml"
    apply_with_retry "$MANIFEST_DIR/vdbe.yaml" 6 || { t_fail "Elastic CR rejected"; return 0; }
    local tc; tc=$(date +%s)
    wait_db_ready "$VDBE" "$DBE_NAME" 1 "$DB_CREATE_TIMEOUT" "Elastic database $DBE_NAME up (1 node)" || { t_fail "Elastic DB not ready"; return 0; }
    metric "scaling.create_db_1node" "$(( $(date +%s) - tc ))" "s"
    load_dataset "$host" "$sdb" 500000
  fi
  local sc_json t0
  sc_json=$(jq -cn --arg cpu "$cpu" --arg mem "${mem}Gi" --arg st "$svctype" --arg db "$svdb" --arg np "$np" '
    {name:"analytics", type:"secondary", size:1, serviceType:$st,
     resources:{requests:{cpu:$cpu,memory:$mem}, limits:{cpu:$cpu,memory:$mem}},
     affinity:{podAntiAffinity:{preferredDuringSchedulingIgnoredDuringExecution:[{weight:100,podAffinityTerm:{labelSelector:{matchLabels:{"vertica.com/subcluster-selector-name":($db + "-analytics")}},topologyKey:"kubernetes.io/hostname"}}]}}}
    + (if $np != "" then {clientNodePort: ($np|tonumber)} else {} end)')
  t_info "SCALE-OUT: add secondary subcluster 'analytics' (size 1)"
  run --label "kubectl -n $NS patch vdb $svdb --type=json  ->  add subcluster 'analytics' (secondary, size 1, ${cpu} CPU / ${mem}Gi, $svctype, soft anti-affinity)" \
    kc -n "$NS" patch vdb "$svdb" --type=json -p "[{\"op\":\"add\",\"path\":\"/spec/subclusters/-\",\"value\":$sc_json}]"
  t0=$(date +%s); WATCH_VDB=$svdb; WAIT_HOOK=show_vdb_events
  if wait_until "Subcluster analytics 1 node UP" "$SCALE_TIMEOUT" 5 probe_sc_up "$host" "$sdb" analytics 1 $(( base + 1 )); then
    metric "scaling.add_subcluster" "$(( $(date +%s) - t0 ))" "s"; t_pass "Scale-out: new subcluster added online"
  else
    t_fail "Subcluster add failed — removing it again"
    run --allow-fail kc -n "$NS" describe pod "${svdb}-analytics-0"
    local fidx; fidx=$(sc_index "$svdb" analytics)
    if [[ $fidx =~ ^[0-9]+$ ]]; then run --allow-fail kc -n "$NS" patch vdb "$svdb" --type=json -p "[{\"op\":\"remove\",\"path\":\"/spec/subclusters/$fidx\"}]"; fi
    WAIT_HOOK=""; WATCH_VDB=""; return 0
  fi
  local idx; idx=$(sc_index "$svdb" analytics)
  t_info "SCALE-OUT: analytics size 1 -> 2"
  run kc -n "$NS" patch vdb "$svdb" --type=json -p "[{\"op\":\"replace\",\"path\":\"/spec/subclusters/$idx/size\",\"value\":2}]"
  t0=$(date +%s)
  if wait_until "Subcluster analytics 2 nodes UP" "$SCALE_TIMEOUT" 5 probe_sc_up "$host" "$sdb" analytics 2 $(( base + 2 )); then
    metric "scaling.scale_out_1_to_2" "$(( $(date +%s) - t0 ))" "s"; t_pass "Scale-out: analytics grew to 2 nodes"; else t_fail "Scale-out to 2 failed"; fi
  WAIT_HOOK=""; WATCH_VDB=""
  vsql_show "$host" "$sdb" "Subcluster topology after scale-out" "SELECT subcluster_name, is_primary, COUNT(*) nodes FROM v_catalog.subclusters GROUP BY 1,2 ORDER BY 2 DESC;" || true
  # subcluster workload isolation
  local asvc="${svdb}-analytics" i bad=0 got
  for i in 1 2 3 4 5 6; do
    got=$(vsql_t 60 "$asvc" "$sdb" "SELECT s.subcluster_name FROM v_monitor.current_session c JOIN v_catalog.subclusters s ON s.node_name=c.node_name;" 2>/dev/null | tr -d '[:space:]' || true)
    [[ $got == analytics ]] || bad=1
  done
  (( bad == 0 )) && t_pass "Workload isolation: every session via service $asvc lands on the analytics subcluster" || t_fail "Sessions via $asvc landed outside analytics"
  bad=0
  for i in 1 2 3 4; do
    got=$(vsql_t 60 "$host" "$sdb" "SELECT s.subcluster_name FROM v_monitor.current_session c JOIN v_catalog.subclusters s ON s.node_name=c.node_name;" 2>/dev/null | tr -d '[:space:]' || true)
    [[ $got == primary ]] || bad=1
  done
  (( bad == 0 )) && t_pass "Workload isolation: sessions via $host stay on the primary subcluster" || t_fail "Primary service routed outside primary"
  local tag; tag="s$(date +%H%M%S)"
  for i in 1 2 3; do vsql_c "$host" "$sdb" "SELECT /*+LABEL(lab_sc_${tag}_idle)*/ COUNT(*) FROM lab.sales WHERE sale_id % 97 = 1;" >/dev/null; done
  printf '%s\n' "$DB_PASSWORD" | timeout 600 "${KC[@]}" exec -i -n "$NS" "$CLIENT_POD" -c client -- sh -c '
    h=$1; d=$2; IFS= read -r VSQL_PASSWORD; export VSQL_PASSWORD; i=0
    while [ $i -lt 6 ]; do /opt/vertica/bin/vsql -m prefer -X -q -At -h "$h" -d "$d" -U dbadmin -c "SELECT SUM(x) FROM (SELECT ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY sale_ts, sale_id) x FROM lab.sales) q" >/dev/null 2>&1 & i=$((i+1)); done; wait' \
    sh "$asvc" "$sdb" >/dev/null 2>&1 &
  local hp=$!; BG_PIDS+=("$hp"); sleep 3
  for i in 1 2 3; do vsql_c "$host" "$sdb" "SELECT /*+LABEL(lab_sc_${tag}_busy)*/ COUNT(*) FROM lab.sales WHERE sale_id % 97 = 1;" >/dev/null; done
  wait "$hp" 2>/dev/null || true; sleep 2
  metric "isolation.primary_latency_idle" "$(sql1 "$host" "$sdb" "SELECT ROUND(AVG(request_duration_ms)) FROM v_monitor.query_requests WHERE request_label='lab_sc_${tag}_idle';")" "ms"
  metric "isolation.primary_latency_analytics_busy" "$(sql1 "$host" "$sdb" "SELECT ROUND(AVG(request_duration_ms)) FROM v_monitor.query_requests WHERE request_label='lab_sc_${tag}_busy';")" "ms" "shared workstation CPU"
  # scale-in
  t_info "SCALE-IN: analytics 2 -> 1"
  run kc -n "$NS" patch vdb "$svdb" --type=json -p "[{\"op\":\"replace\",\"path\":\"/spec/subclusters/$idx/size\",\"value\":1}]"
  t0=$(date +%s)
  wait_until "Subcluster analytics back to 1 node" "$SCALE_TIMEOUT" 5 probe_sc_up "$host" "$sdb" analytics 1 $(( base + 1 )) \
    && { metric "scaling.scale_in_2_to_1" "$(( $(date +%s) - t0 ))" "s"; t_pass "Scale-in: node drained and removed from catalog"; } || t_fail "Scale-in failed"
  t_info "SCALE-IN: remove subcluster analytics"
  run kc -n "$NS" patch vdb "$svdb" --type=json -p "[{\"op\":\"remove\",\"path\":\"/spec/subclusters/$idx\"}]"
  t0=$(date +%s)
  wait_until "Subcluster analytics removed" "$SCALE_TIMEOUT" 5 probe_sc_up "$host" "$sdb" analytics 0 "$base" \
    && { metric "scaling.remove_subcluster" "$(( $(date +%s) - t0 ))" "s"; t_pass "Subcluster removed; database back to $base node(s)"; } || t_fail "Subcluster removal failed"
  # the operator keeps PVCs of removed pods (data safety); delete the scaling test's volumes explicitly
  local lp; lp=$(kc -n "$NS" get pvc -o name 2>/dev/null | grep "local-data-${svdb}-analytics-" || true)
  if [[ -n $lp ]]; then
    t_info "Removing the analytics subcluster's leftover volumes ($(wc -l <<<"$lp" | tr -d ' ') PVCs; the operator keeps PVCs on scale-in by design)"
    xargs -r "${KC[@]}" -n "$NS" delete --wait=false <<<"$lp" >>"$LOG_FILE" 2>&1 || true
  fi
  if [[ $svdb == "$VDBE" ]]; then
    t_info "Operator full-cluster restart: deleting the only primary pod of $sdb (K-safety 0 => database goes DOWN)"
    run kc -n "$NS" delete pod "${VDBE}-primary-0" --wait=false
    t0=$(date +%s); sleep 5
    if wait_db_ready "$VDBE" "$DBE_NAME" 1 "$SCALE_TIMEOUT" "Operator restarts the whole database"; then
      metric "selfheal.full_cluster_restart" "$(( $(date +%s) - t0 ))" "s"; t_pass "Operator automatically restarted a fully DOWN database"
    else t_fail "Full-cluster restart failed"; fi
    t_info "Removing the temporary elastic database (CR, PVCs, communal objects)"
    run --allow-fail kc -n "$NS" delete vdb "$VDBE" --wait=true --timeout=600s
    if [[ $(state_get MINIO_MC) == 1 ]]; then local ep; ep=$(state_get ELASTIC_PATH); run --allow-fail kc -n "$MINIO_NS" exec deploy/minio -- mc rm --recursive --force "local/${ep#s3://}"; fi
  fi
}

t15_final() {
  health_checks "$VDB" "$DB_NAME" 3 test
  host_vertica_snapshot >"$RUN_DIR/host-vertica-after.txt"
  if diff -q "$RUN_DIR/host-vertica-before.txt" "$RUN_DIR/host-vertica-after.txt" >/dev/null; then
    t_pass "Host Vertica untouched: version, processes, ports, config mtime, dbadmin and unit identical to run start"
  else
    t_fail "Host Vertica snapshot changed during the run:"; diff "$RUN_DIR/host-vertica-before.txt" "$RUN_DIR/host-vertica-after.txt" | sed 's/^/      /' || true
  fi
  local c paused=0; for c in $(lab_containers); do [[ $(docker inspect -f '{{.State.Status}}' "$c") == running ]] || paused=1; done
  (( paused == 0 )) && t_pass "All kind node containers running (none left paused/stopped)" || t_fail "Some kind nodes not running"
  local rp; rp=$(for c in $(lab_containers); do docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$c"; done | sort -u | tr '\n' ' ')
  [[ $rp == "no " ]] && t_pass "Reboot safety: kind node restart policy = no" || t_warn "Restart policies: $rp"
  kc -n "$NS" get vdb "$VDBE" >/dev/null 2>&1 && t_warn "Temporary elastic DB still present" || t_pass "No temporary test objects left behind"
}

prod_only_items() {
  cat <<'EOF'
P01|Permanent host loss with pod rescheduling onto another physical machine|Local-path PVs pin each Vertica pod to one node; production needs network/replicated CSI storage (EBS, Ceph, Portworx, vSAN) so the StatefulSet pod can restart elsewhere.
P02|Kubernetes control-plane high availability|kind here has 1 control-plane; production uses 3+ control-plane nodes / managed K8s with an etcd quorum.
P03|Zone / rack fault domains|Needs real failure domains with topologySpreadConstraints / zone labels; all 'nodes' here share one workstation.
P04|Real network partitions, NIC/switch failures and latency between hosts|Simulated only by freezing a node container; real Spread heartbeat behaviour needs separate hosts.
P05|Production performance and capacity benchmarks|All pods share the same CPU, RAM and SSD; numbers are relative, not sizing guidance.
P06|Durable communal storage|A single MinIO pod on one disk is not durable; production uses S3 or an erasure-coded/replicated on-prem object store with TLS.
P07|Off-site / cross-region disaster recovery|Requires a second cluster (VerticaReplicator CR or replicated object storage).
P08|Metrics-driven autoscaling (VerticaAutoscaler + Prometheus/KEDA) and K8s node autoscaling|Needs a cluster autoscaler / cloud capacity; here scaling is triggered by CR changes.
P09|Online rolling upgrade between Vertica releases (upgradePolicy: Online)|Needs a second, newer image version and production-sized subclusters.
P10|Enterprise identity & secrets (LDAP/Kerberos, AWS Secrets Manager / Google Secret Manager, CA-signed certificates, etcd encryption at rest)|Requires corporate infrastructure; the lab uses Kubernetes Secrets and operator self-signed certificates.
P11|Load balancers / ingress with real external IPs and DNS|Lab exposes NodePorts on 127.0.0.1 only.
P12|Workload identity for communal storage (IRSA on Amazon EKS)|Vertica pods use their service-account JWT, exchanged through the cluster's OIDC provider for temporary S3 credentials, so no static access keys are stored (Vertica docs: IRSA profile authentication). Needs EKS and AWS IAM.
P13|Production identity provider for OAuth 2.0 / JWT (Okta, OTDS, or Keycloak in production mode)|The lab Keycloak runs in dev mode (in-memory database, HTTP inside the cluster). Production: HTTPS endpoints, a highly available IdP, just-in-time user provisioning and role mapping from token claims.
EOF
}

write_report() {
  local f="$RUN_DIR/summary.txt" pass fail warn skip total
  pass=$(grep -c ',PASS,' "$RESULTS_CSV" || true); fail=$(grep -c ',FAIL,' "$RESULTS_CSV" || true)
  warn=$(grep -c ',WARN,' "$RESULTS_CSV" || true); skip=$(grep -c ',SKIP,' "$RESULTS_CSV" || true)
  total=$(( pass + fail + warn + skip ))
  banner "TEST SUMMARY" "$(date '+%F %T') | host $(hostname) | Vertica image $(state_get VERTICA_IMAGE_RESOLVED) | chart $(state_get OPERATOR_CHART_VERSION_RESOLVED)"
  printf '  %s%-5s %-11s %-18s %-6s %6s  %s%s\n' "$C_BOLD" "ID" "GROUP" "SCOPE" "STATUS" "SECS" "TEST" "$C_RESET"
  local id group scope status dur title msg col nprod=0
  while IFS=, read -r id group scope status dur rest; do
    [[ $id == id ]] && continue
    title=$(cut -d'"' -f2 <<<"$rest")
    # PROD-ONLY rows (status N/A) are not executed here: log/report only, not on screen
    if [[ $status == N/A ]]; then nprod=$(( nprod + 1 )); _log "      $id  production  PROD  N/A  $title"; continue; fi
    col=$C_GREEN; [[ $status == FAIL ]] && col=$C_RED; [[ $status == WARN ]] && col=$C_YELLOW; [[ $status == SKIP ]] && col=$C_DIM
    local sl; case $scope in REAL) sl="LOCAL-REAL";; SIM) sl="LOCAL-SIMULATED";; *) sl=$scope;; esac
    printf '  %-5s %-11s %-18s %s%-6s%s %6s  %s\n' "$id" "$group" "$sl" "$C_BOLD$col" "$status" "$C_RESET" "$dur" "$title"
  done <"$RESULTS_CSV"
  printf '\n  %sTotals:%s %s%d PASS%s  %s%d FAIL%s  %s%d WARN%s  %d SKIP  (of %d)\n' "$C_BOLD" "$C_RESET" "$C_GREEN" "$pass" "$C_RESET" \
    "$C_RED" "$fail" "$C_RESET" "$C_YELLOW" "$warn" "$C_RESET" "$skip" "$total"
  printf '\n  %sKey performance / recovery metrics%s\n' "$C_BOLD" "$C_RESET"
  awk -F, 'NR>1 && ($2 ~ /recovery|detect|rto|outage|throughput|availability|median|add_subcluster|scale_|restart|save_restore|table_restore|cold|warm/) {gsub(/"/,"",$5); printf "    %-5s %-44s %10s %-8s %s\n", $1, $2, $3, $4, $5}' "$PERF_CSV" | head -n 45
  # PROD-ONLY capabilities: full list in the log and summary.txt only (kept off the screen)
  local pid ptitle preason np
  np=$(prod_only_items | grep -c . || true)
  printf '\n  %s%s%s %d PROD-ONLY capabilities need a real multi-node production cluster (not testable on one workstation) — listed in the log and in summary.txt\n' \
    "$C_MAGENTA" "$U_INFO" "$C_RESET" "$np"
  _log "Capabilities that REQUIRE a real multi-node production cluster (not testable on one workstation):"
  while IFS='|' read -r pid ptitle preason; do _log "      $pid  $ptitle — $preason"; done < <(prod_only_items)
  printf '\n  %sLegend:%s LOCAL-REAL = the real Vertica/Kubernetes mechanism ran exactly as in production.\n' "$C_BOLD" "$C_RESET"
  printf '          LOCAL-SIMULATED = real mechanism, but the failure/scale event is simulated (nodes are containers on one host).\n'
  {
    echo "Vertica Kubernetes Operator lab — test report ($(date '+%F %T'))"
    echo "Host: $(hostname)  Image: $(state_get VERTICA_IMAGE_RESOLVED)  Operator chart: $(state_get OPERATOR_CHART_VERSION_RESOLVED)"
    echo "Totals: PASS=$pass FAIL=$fail WARN=$warn SKIP=$skip"
    echo; echo "Results (id,group,scope,status,seconds,title,message):"; cat "$RESULTS_CSV"
    echo; echo "Metrics (test,metric,value,unit,note):"; cat "$PERF_CSV"
    echo; echo "PROD-CLUSTER-ONLY capabilities:"; prod_only_items | tr '|' '\t'
    echo; echo "Detailed per-test assertions:"; for id in ${T_ORDER[@]+"${T_ORDER[@]}"}; do if [[ -f $RUN_DIR/results/$id.res ]]; then sed "s/^/$id  /" "$RUN_DIR/results/$id.res"; fi; done
  } | while IFS= read -r l; do _mask "$l"; echo; done >"$f"
  printf '\n  %sReports:%s %s\n           %s\n           %s\n' "$C_BOLD" "$C_RESET" "$f" "$RESULTS_CSV" "$PERF_CSV"
  [[ $fail -eq 0 ]]
}

# ---------- test catalog: id|group|scope|clear title|function|estimated time ----------
TEST_CATALOG=(
  "T01|health|REAL|Cluster health check|t01_health|~10 s"
  "T02|workload|REAL|SQL workload: build and verify a star schema|t02_workload|~30 s"
  "T03|perf|REAL|Query performance, concurrency and bulk load|t03_perf|~1 min"
  "T04|storage|REAL|Persistent storage (local volumes + S3 communal)|t04_storage|~5 s"
  "T05|monitoring|REAL|Monitoring and metrics endpoints|t05_monitoring|~15 s"
  "T06|security|REAL|Security controls (secrets, RBAC, TLS, network)|t06_security|~40 s"
  "T07|m2m|REAL|Machine-to-machine database login (OAuth 2.0 / JWT)|t07_m2m|~1 min"
  "T08|isolation|REAL|Workload isolation with resource pools|t08_isolation|~1 min"
  "T09|reconcile|REAL|Operator auto-repair of configuration drift|t09_reconcile|~2-4 min"
  "T10|selfheal|SIM|Self-healing: Vertica process crash|t10_selfheal_process|~1-2 min"
  "T11|selfheal|SIM|Self-healing: Vertica pod deleted|t11_selfheal_pod|~1-2 min"
  "T12|nodefail|SIM|Node failure: a worker server freezes|t12_nodefail|~2-3 min"
  "T13|backup|REAL|Backup, restore and disaster recovery|t13_backup|~5-10 min"
  "T14|scaling|SIM|Elastic scaling: add and remove compute online|t14_scaling|~5-10 min"
  "T15|final|REAL|Final health and host-safety check|t15_final|~15 s"
)
# Plain-language briefing printed before each test (WHAT / HOW steps / EXPECT / WATCH / TIME)
test_brief() {
  local rows; rows=$(state_get SALES_ROWS 2000000)
  case $1 in
    T01) cat <<EOF
WHAT|A quick check-up of every layer before any test changes anything.
HOW|Check the 4 Kubernetes nodes, the VerticaDB operator, its admission webhook and MinIO (S3 communal storage).
HOW|Check the 3 Vertica pods and their volumes, the Vertica node states, K-safety and the license.
EXPECT|All green: 4/4 nodes Ready, 3/3 pods Ready, 3/3 Vertica nodes UP, K-safety 1.
TIME|~10 s
EOF
    ;;
    T02) cat <<EOF
WHAT|Builds a realistic retail star schema inside Vertica and checks the data is correct and evenly spread.
HOW|Generate 10,000 customers, 1,000 products and $rows sales rows with set-based SQL (no files needed).
HOW|Verify the row count and referential integrity (every sale has a customer).
HOW|Show how the rows are distributed over the 3 nodes (segmentation).
EXPECT|Exact row count, 0 orphan rows, segmentation skew close to 1.00 (= perfectly even).
TIME|~30 s
EOF
    ;;
    T03) cat <<EOF
WHAT|Measures how fast the cluster answers typical analytic questions and loads data.
HOW|Run 6 analytic queries 3 times each (joins, window functions, percentiles); timings come from Vertica itself.
HOW|Eon depot effect: clear the local cache, run a query "cold" (reads S3) and then "warm" (local depot).
HOW|Concurrency: 8 parallel sessions x 5 queries. Bulk load: COPY 500,000 CSV rows.
EXPECT|All queries succeed, a timing table is printed, 0 errors under concurrency, exactly 500,000 rows loaded.
WATCH|Numbers are relative: all 3 "servers" share this workstation's CPU and SSD.
TIME|~1 min
EOF
    ;;
    T04) cat <<EOF
WHAT|Shows where Vertica keeps its data and proves it is stored durably.
HOW|List the PersistentVolumeClaims (one local volume per pod for catalog + depot cache).
HOW|Show Vertica's storage locations and count the data files in the S3 communal bucket (MinIO).
EXPECT|3 Bound volumes, a COMMUNAL storage location, data objects present in S3.
TIME|~5 s
EOF
    ;;
    T05) cat <<EOF
WHAT|Checks every monitoring channel an operations team would use.
HOW|kubectl top (metrics-server) for nodes and pods.
HOW|Operator Prometheus /metrics with a JWT bearer token: the pod's Kubernetes service-account token (machine-to-machine).
HOW|The same endpoint with no token, a tampered JWT, a JWT for another audience, and another service account's JWT.
HOW|Vertica server Prometheus endpoint (HTTPS 8443), Vertica system tables (v_monitor), Kubernetes events.
EXPECT|Metrics with a valid JWT; no token, a tampered JWT or a JWT for another audience are REJECTED.
WATCH|No Kubernetes events is normal for a stable DB (events are kept 1 h); raw metric samples go to the log only.
TIME|~15 s
EOF
    ;;
    T06) cat <<EOF
WHAT|Verifies the security controls: secrets, least privilege, encryption and network isolation.
HOW|DB password lives only in a Kubernetes Secret; Vertica runs as non-root; a read-only service account is limited.
HOW|Database users: a read-only user can SELECT but not INSERT; a failed login is audited.
HOW|TLS: a TLS login is accepted and a plain-text login is REJECTED (TLS missing or not enforced = WARN, not FAIL).
HOW|Inter-node TLS: data channel (data_channel TLS, VERIFY_CA) and control channel (Spread encryption) between the nodes.
HOW|NetworkPolicy: an unlabelled "intruder" pod is blocked from the SQL port 5433.
EXPECT|Every control PASSes; the intruder can connect before the policy and is blocked after it.
TIME|~40 s
EOF
    ;;
    T07) cat <<EOF
WHAT|An ETL service logs into Vertica with a signed token (JWT) from Keycloak instead of a password.
HOW|The service gets a token with its client credentials (OAuth 2.0 client_credentials grant): no user, no password.
HOW|Vertica validates the JWT itself: signature (keys from the JWKS URL), issuer, audience, scope and expiry.
HOW|Negative tests: tampered signature, forged payload, wrong audience, expired token, password login.
HOW|Least privilege and audit; then the identity provider rotates its signing key.
EXPECT|Valid token = session as svc_etl over TLS (method OAuth); every forged/expired/wrong token is REJECTED.
WATCH|The session user always comes from the token, even if the client asks for 'dbadmin'.
TIME|~1 min (includes a 20 s wait for a token to expire)
EOF
    ;;
    T08) cat <<EOF
WHAT|Shows that heavy ETL jobs cannot starve interactive BI users.
HOW|Create 2 resource pools: lab_etl_pool (max 2 concurrent, low priority) and lab_bi_pool (high priority).
HOW|Fire 12 heavy ETL queries at once while BI queries keep running.
EXPECT|ETL queries run in lab_etl_pool (extra ones queue), BI queries run in lab_bi_pool.
TIME|~1 min
EOF
    ;;
    T09) cat <<EOF
WHAT|Proves the operator automatically repairs anything that drifts from the desired state (the VerticaDB CR).
HOW|Delete an operator-managed Service: the operator recreates it.
HOW|Scale the StatefulSet from 3 to 2 by hand: the operator restores 3 and the Vertica node rejoins.
HOW|Delete the operator pod itself: the database keeps running and the new operator resumes.
HOW|Try invalid CR edits (server-side dry-run): the admission webhook rejects them.
EXPECT|Every drift is undone automatically and the database stays available.
TIME|~2-4 min (each wait is capped at ${RECOVERY_TIMEOUT}s)
EOF
    ;;
    T10) cat <<EOF
WHAT|Simulates Vertica crashing on one node (like an out-of-memory kill) while an application keeps querying.
HOW|Start a client application: 1 query per second for ${LOAD_SECONDS}s.
HOW|SIGKILL the Vertica process of node 2 and watch the cluster mark it DOWN.
HOW|Kubernetes restarts the container, the operator restarts Vertica and the node rejoins.
EXPECT|Database stays UP on 2 of 3 nodes (K-safety 1), node 2 is back UP, the application recovers by itself.
WATCH|The client timeline bar: 1 block = 1 second (green = queries OK, red = short outage while the cluster re-forms).
TIME|~1-2 min (recovery capped at ${RECOVERY_TIMEOUT}s)
EOF
    ;;
    T11) cat <<EOF
WHAT|Deletes a whole Vertica pod (like an eviction) and checks it comes back with its own data.
HOW|Record the row count and the pod's volume, then start the client application (1 query/s for ${LOAD_SECONDS}s).
HOW|kubectl delete pod: the StatefulSet recreates it, the operator restarts Vertica in it.
HOW|Check the same PersistentVolume was re-attached and that no rows were lost.
EXPECT|Pod recreated, node rejoins, same volume, row count unchanged, the application recovers by itself.
TIME|~1-2 min (recovery capped at ${RECOVERY_TIMEOUT}s)
EOF
    ;;
    T12) cat <<EOF
WHAT|Freezes an entire worker "server" (docker pause): kubelet, container runtime and Vertica all stop responding.
HOW|Start the client application, then freeze a worker that hosts one Vertica pod for ${NODE_FAIL_SECONDS}s.
HOW|While it is frozen: write and read data through the 2 surviving nodes.
HOW|Unfreeze it: the node returns and the operator brings Vertica back to 3/3 UP.
EXPECT|Reads AND writes keep working with 1 node lost; full recovery and application recovery without manual action.
TIME|~2-3 min (recovery capped at ${RECOVERY_TIMEOUT}s)
EOF
    ;;
    T13) cat <<EOF
WHAT|A full backup and disaster-recovery drill driven by the operator.
HOW|Save a restore point (VerticaRestorePointsQuery), then simulate incidents: unwanted inserts and a DROP TABLE.
HOW|Logical backup: export a table to Parquet in S3 and read it back (auto-skipped on the -minimal image, which has no Parquet export package).
HOW|Restore only the dropped table from the restore point.
HOW|DISASTER: delete the whole database deployment (pods + volumes) and revive it from S3 at the restore point.
EXPECT|Dropped table restored; after the revive the data matches the restore point exactly.
WATCH|The database is intentionally OFFLINE for a few minutes during the revive step.
TIME|~5-10 min
EOF
    ;;
    T14) cat <<EOF
WHAT|Adds and removes compute online: a secondary "analytics" subcluster with its own service.
HOW|Add subcluster 'analytics' with 1 node, then grow it to 2 nodes.
HOW|Route sessions through each subcluster's service and run heavy queries on analytics only.
HOW|Scale analytics back 2 -> 1 and remove it.
EXPECT|Every scaling step completes online and sessions land on the right subcluster.
TIME|~5-10 min
EOF
    ;;
    T15) cat <<EOF
WHAT|Confirms the lab is left healthy and the host is untouched.
HOW|Repeat the health check.
HOW|Compare the host Vertica 26.3 (version, processes, ports, config) with the snapshot from the start.
HOW|Check no kind node is left paused and none will auto-start after a reboot.
EXPECT|Healthy cluster, host Vertica identical, restart policy = no.
TIME|~15 s
EOF
    ;;
  esac
}
print_test_plan() {
  local e id group scope title fn est n=0 w
  w=$(( TERM_COLS > 110 ? 110 : TERM_COLS - 2 ))
  printf '\n%s%s%s\n' "$C_BOLD$C_BLUE" "$(_hr "$U_HL" "$w")" "$C_RESET"
  printf '  %s TEST PLAN %s  %s%d tests will run%s %s(failure tests use a %ss client load; every recovery wait is capped at %ss)%s\n' \
    "$C_BOLD$C_WHITE$C_BGBLUE" "$C_RESET" "$C_BOLD" "$T_TOTAL" "$C_RESET" "$C_DIM" "$LOAD_SECONDS" "$RECOVERY_TIMEOUT" "$C_RESET"
  printf '%s%s%s\n' "$C_BLUE" "$(_hr "$U_THIN" "$w")" "$C_RESET"
  printf '  %s%-9s %-52s %-17s %s%s\n' "$C_BOLD" "#" "TEST" "SCOPE" "EST. TIME" "$C_RESET"
  for e in "${TEST_CATALOG[@]}"; do
    IFS='|' read -r id group scope title fn est <<<"$e"
    if group_selected "$group"; then
      n=$(( n + 1 ))
      printf '  %-9s %-52s %s%-17s%s %s\n' "$n from $T_TOTAL" "$title" "$([[ $scope == SIM ]] && echo "$C_YELLOW" || echo "$C_GREEN")" \
        "$([[ $scope == SIM ]] && echo LOCAL-SIMULATED || echo LOCAL-REAL)" "$C_RESET" "$est"
    else
      printf '  %s%-9s %-52s %-17s %s%s\n' "$C_DIM" "-" "$title" "skipped" "(--only/--skip)" "$C_RESET"
    fi
  done
  printf '%s%s%s\n' "$C_BOLD$C_BLUE" "$(_hr "$U_HL" "$w")" "$C_RESET"
}

# Installs made before 2026-11-04 used a required anti-affinity on a label shared by ALL pods of the
# database, which made secondary-subcluster pods unschedulable on 3 workers. Migrate it in place
# (the operator rolls the primary pods one at a time; the database stays K-safe and online).
sts_rolled_probe() { # sts
  local j; j=$(kc -n "$NS" get sts "$1" -o json 2>/dev/null || echo '{}')
  local r u rd; r=$(jq -r '.spec.replicas // 0' <<<"$j"); u=$(jq -r '.status.updatedReplicas // 0' <<<"$j"); rd=$(jq -r '.status.readyReplicas // 0' <<<"$j")
  printf 'pods on new spec %s/%s, ready %s/%s' "$u" "$r" "$rd" "$r"
  [[ $r -gt 0 && $u == "$r" && $rd == "$r" ]]
}
migrate_primary_affinity() {
  local j idx cur
  j=$(kc -n "$NS" get vdb "$VDB" -o json 2>/dev/null) || return 0
  idx=$(jq '.spec.subclusters | map(.name) | index("primary")' <<<"$j"); [[ $idx =~ ^[0-9]+$ ]] || return 0
  cur=$(jq -r --argjson i "$idx" '.spec.subclusters[$i].affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution // [] | map(.labelSelector.matchLabels | keys[]) | join(",")' <<<"$j")
  [[ $cur == "vertica.com/subcluster-selector-name" ]] && return 0
  info "Migrating primary pod anti-affinity: repel only primary pods (secondary subcluster pods may share workers)"
  local v; v=$(jq -cn --arg s "${VDB}-primary" '{podAntiAffinity:{requiredDuringSchedulingIgnoredDuringExecution:[{labelSelector:{matchLabels:{"vertica.com/subcluster-selector-name":$s}},topologyKey:"kubernetes.io/hostname"}]}}')
  run --label "kubectl -n $NS patch vdb $VDB --type=json  ->  set subcluster $idx affinity: required anti-affinity between primary pods" \
    kc -n "$NS" patch vdb "$VDB" --type=json -p "[{\"op\":\"replace\",\"path\":\"/spec/subclusters/$idx/affinity\",\"value\":$v}]"
  sleep 10
  WATCH_VDB=$VDB; WAIT_HOOK=show_vdb_events
  wait_until "Operator rolls the primary pods onto the new spec (one at a time, DB stays online)" 1200 5 sts_rolled_probe "${VDB}-primary" || warn "Rolling update not complete yet"
  WAIT_HOOK=""; WATCH_VDB=""
}

do_test() {
  [[ $(state_get INSTALL_COMPLETE) == 1 ]] || die "Lab not installed. Run: sudo $SCRIPT_PATH --install"
  banner "VERTICA KUBERNETES OPERATOR $VERTICA_TARGET_VERSION — PRODUCTION-READINESS TEST SUITE" "$(date '+%F %T') | log: $LOG_FILE"
  detect_arch
  RESULTS_CSV="$RUN_DIR/results.csv"; PERF_CSV="$RUN_DIR/perf.csv"
  echo 'id,group,scope,status,seconds,title,message' >"$RESULTS_CSV"; echo 'test,metric,value,unit,note' >"$PERF_CSV"
  host_vertica_snapshot >"$RUN_DIR/host-vertica-before.txt"
  info "Host Vertica snapshot (read-only) taken at start of run:"; show_host_snapshot "$RUN_DIR/host-vertica-before.txt"
  info "Preparing: making sure the lab cluster and database are running"
  start_stopped_nodes; disable_node_autostart
  wait_until "Kubernetes nodes Ready" 600 5 nodes_ready_probe || die "Cluster not healthy. Try --cleanup then --install."
  wait_until "SQL client pod ready" 600 5 client_probe || die "Client pod not ready"
  kc -n "$NS" delete vdb "$VDBE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  wait_db_ready "$VDB" "$DB_NAME" 3 1800 "Main database ready (3/3)" || die "Main database not ready — see --status"
  migrate_primary_affinity
  wait_db_ready "$VDB" "$DB_NAME" 3 1800 "Main database ready (3/3)" || die "Main database not ready — see --status"
  group_selected workload || ensure_dataset
  local e id group scope title fn est
  T_TOTAL=0; T_NUM=0; T_STATUSES=()
  for e in "${TEST_CATALOG[@]}"; do IFS='|' read -r id group scope title fn est <<<"$e"; if group_selected "$group"; then T_TOTAL=$(( T_TOTAL + 1 )); fi; done
  print_test_plan
  for e in "${TEST_CATALOG[@]}"; do
    IFS='|' read -r id group scope title fn est <<<"$e"
    run_test "$id" "$group" "$scope" "$title" "$fn"
  done
  local pid ptitle preason
  while IFS='|' read -r pid ptitle preason; do
    printf '%s,%s,%s,%s,%s,"%s","%s"\n' "$pid" "production" "PROD" "N/A" 0 "$ptitle" "${preason//,/;}" >>"$RESULTS_CSV"
  done < <(prod_only_items)
  TEST_EXIT=0
  if write_report; then banner "ALL EXECUTED TESTS PASSED (warnings may need review)"
  else TEST_EXIT=1; banner "SOME TESTS FAILED — see the report and log"; fi
  return 0
}

#==============================================================================
# --status (read-only)
#==============================================================================
do_status() {
  banner "VERTICA K8S LAB — STATUS" "$(date '+%F %T') | read-only"
  printf '\n%s[1] Lab installation%s\n' "$C_BOLD" "$C_RESET"
  if [[ -f $STATE_FILE ]]; then
    kv "Installed / time" "$(state_get INSTALL_COMPLETE 0) / $(state_get INSTALL_TIME n/a)"
    kv "Vertica image" "$(state_get VERTICA_IMAGE_RESOLVED n/a)"
    kv "Operator chart" "$(state_get OPERATOR_CHART_VERSION_RESOLVED n/a)"
    kv "Communal path" "$(state_get COMMUNAL_PATH n/a)"
    kv "Pod sizing" "$(state_get VDB_MEM_GB "?") GiB / $(state_get VDB_CPU_CORES "?") CPU per Vertica pod"
    kv "License secret" "$( [[ -n $(state_get LICENSE_INSTALLED) ]] && echo "yes ($(state_get LICENSE_SOURCE))" || echo "no (image default)")"
    kv "Docker installed by lab" "$( [[ $(state_get DOCKER_INSTALLED_BY_LAB) == 1 ]] && echo yes || echo 'no (pre-existing)')"
  else
    info "No lab state found at $STATE_FILE — the lab is not installed."
    do_verify_clean; return 0
  fi
  printf '\n%s[2] Host Vertica (read-only)%s\n' "$C_BOLD" "$C_RESET"
  host_vertica_snapshot | while IFS='=' read -r k v; do kv "$k" "$v"; done
  kv "Host RAM available" "$(( $(mem_kb MemAvailable) / 1048576 )) GB of $(( $(mem_kb MemTotal) / 1048576 )) GB"
  printf '\n%s[3] Docker / kind node containers%s\n' "$C_BOLD" "$C_RESET"
  if docker_ok; then
    docker ps -a --filter "label=io.x-k8s.kind.cluster=$CLUSTER_NAME" --format '{{.Names}}\t{{.Status}}' | while IFS=$'\t' read -r n s; do
      kv "$n" "$s | restart=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$n")"
    done
    docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' $(lab_containers) 2>/dev/null | while IFS=$'\t' read -r n c m; do kv "  usage $n" "CPU $c  MEM $m"; done || true
  else warn "Docker not running"; fi
  printf '\n%s[4] Kubernetes%s\n' "$C_BOLD" "$C_RESET"
  if k8s_reachable; then
    local tmpd; tmpd=$(mktemp -d); TMPDIR_LAB=$tmpd
    run --show --allow-fail kc get nodes -o wide
    run --show --allow-fail kc -n "$NS" get vdb,vrpq,sts,pods,pvc,svc -o wide
    run --show --allow-fail kc -n "$OP_NS" get pods -o wide
    run --show --allow-fail kc -n "$MINIO_NS" get pods,pvc
    [[ $(state_get OAUTH_INSTALLED) == 1 ]] && run --show --allow-fail kc -n "$IDP_NS" get pods,svc
    run --show --allow-fail kc top pods -n "$NS"
    printf '\n%s[5] Database%s\n' "$C_BOLD" "$C_RESET"
    if client_probe >/dev/null 2>&1; then
      vsql_show "${VDB}-primary" "$DB_NAME" "Nodes" "SELECT n.node_name, n.node_state, n.node_address, s.subcluster_name, s.is_primary FROM nodes n JOIN subclusters s ON s.node_name = n.node_name ORDER BY 1;" || warn "Database not answering"
      vsql_show "${VDB}-primary" "$DB_NAME" "Fault tolerance & data" "SELECT (SELECT current_fault_tolerance FROM system) AS k_now, (SELECT COUNT(*) FROM tables WHERE table_schema='lab') AS lab_tables, (SELECT GET_COMPLIANCE_STATUS()) AS license;" || true
    else warn "SQL client pod not running"; fi
    rm -rf "$tmpd"
  else warn "Kubernetes API not reachable (cluster stopped? run --install to start it again)"; fi
  printf '\n%s[6] Last test report%s\n' "$C_BOLD" "$C_RESET"
  local last; last=$(ls -1dt "$REPORT_DIR"/test-* 2>/dev/null | head -n1 || true)
  if [[ -n $last && -f $last/summary.txt ]]; then kv "Report" "$last/summary.txt"; sed -n '3p' "$last/summary.txt" | sed 's/^/    /'
  else kv "Report" "none yet (run --test)"; fi
  printf '\n%s[7] Connect%s\n' "$C_BOLD" "$C_RESET"
  detail "/opt/vertica/bin/vsql -m prefer -h 127.0.0.1 -p $HOST_PORT_PRIMARY -U $DB_USER -d $DB_NAME   (password: sudo grep DB_PASSWORD $SECRETS_FILE)"
}

#==============================================================================
# --info [--watch N]  (read-only live view of pods, Vertica nodes, operator)
#==============================================================================
INFO_WATCH=""
section() { printf '\n%s%s %s %s%s\n' "$C_BOLD$C_CYAN" "$U_HL$U_HL" "$1" "$(_hr "$U_HL" $(( 70 - ${#1} > 2 ? 70 - ${#1} : 2 )))" "$C_RESET"; }
color_state() { # colourise a state word
  case $1 in
    UP|Running|True|Bound|Ready|Succeeded|Available) printf '%s%s%s' "$C_GREEN" "$1" "$C_RESET" ;;
    DOWN|Failed|CrashLoopBackOff|Error|False|Lost|Unknown|OOMKilled) printf '%s%s%s' "$C_RED" "$1" "$C_RESET" ;;
    *) printf '%s%s%s' "$C_YELLOW" "$1" "$C_RESET" ;;
  esac
}
info_vdbs() {
  section "[1] VerticaDB custom resources — desired (spec) vs actual (status)"
  local j; j=$(kc -n "$NS" get vdb -o json 2>/dev/null || echo '{"items":[]}')
  if [[ $(jq '.items | length' <<<"$j") == 0 ]]; then warn "No VerticaDB custom resources in namespace $NS"; return 0; fi
  printf '  %s%-6s %-10s %-34s %-26s %-22s %s%s\n' "$C_BOLD" "CR" "DATABASE" "IMAGE" "SUBCLUSTERS (desired)" "UP NODES (status)" "CONDITIONS=True" "$C_RESET"
  jq -r '.items[] | [ .metadata.name, .spec.dbName, (.spec.image | split("/") | last),
      ([.spec.subclusters[] | "\(.name):\(.size)\(if .type=="primary" then "P" else "S" end)"] | join(" ")),
      ([.status.subclusters[]? | "\(.name)=\(.upNodeCount // 0)"] | join(" ")),
      ([.status.conditions[]? | select(.status=="True") | .type] | join(",")) ] | @tsv' <<<"$j" \
  | while IFS=$'\t' read -r n d i s u c; do printf '  %-6s %-10s %-34s %-26s %s%-22s%s %s\n' "$n" "$d" "$i" "$s" "$C_GREEN" "${u:--}" "$C_RESET" "${c:--}"; done
}
info_pods() {
  section "[2] Pods (lab namespaces) — where each component runs"
  printf '  %s%-20s %-32s %-6s %-18s %-4s %-28s %s%s\n' "$C_BOLD" "NAMESPACE" "POD" "READY" "STATUS" "RST" "K8S NODE" "POD IP" "$C_RESET"
  local ns
  for ns in "$NS" "$OP_NS" "$MINIO_NS" "$IDP_NS"; do
    kc -n "$ns" get pods -o json 2>/dev/null | jq -r '.items[] | [ .metadata.namespace, .metadata.name,
        "\([.status.containerStatuses[]? | select(.ready)] | length)/\([.spec.containers[]] | length)",
        (if .metadata.deletionTimestamp then "Terminating" else
          ([.status.containerStatuses[]? | .state.waiting.reason // empty] | first) // .status.phase end),
        ([.status.containerStatuses[]?.restartCount] | add // 0 | tostring),
        (.spec.nodeName // "-"), (.status.podIP // "-") ] | @tsv' \
    | while IFS=$'\t' read -r a b r s x n ip; do
        printf '  %-20s %-32s %-6s %s%*s %-4s %-28s %s\n' "$a" "$b" "$r" "$(color_state "$s")" $(( 18 - ${#s} > 0 ? 18 - ${#s} : 0 )) '' "$x" "$n" "$ip"
      done || true
  done
  local nn; nn=$(kc get nodes --no-headers 2>/dev/null | awk '{printf "%s(%s) ", $1, $2}')
  printf '  %sKubernetes nodes:%s %s\n' "$C_DIM" "$C_RESET" "$nn"
}
info_vertica_nodes() { # vdb db
  local vdb=$1 db=$2
  section "[3] Vertica nodes of database '$db' (SQL view joined with Kubernetes pods)"
  if ! client_probe >/dev/null 2>&1; then warn "SQL client pod not running"; return 0; fi
  local nodes sess depot pods
  nodes=$(vsql_t 30 "${vdb}-primary" "$db" "SELECT n.node_name, n.node_state, n.node_address, s.subcluster_name, s.is_primary FROM nodes n JOIN subclusters s ON s.node_name=n.node_name ORDER BY 1;" 2>/dev/null || true)
  if [[ -z $nodes ]]; then warn "Database '$db' not answering through service ${vdb}-primary (starting, restarting or down)"; return 0; fi
  sess=$(vsql_t 30 "${vdb}-primary" "$db" "SELECT node_name, COUNT(*) FROM sessions GROUP BY 1;" 2>/dev/null || true)
  depot=$(vsql_t 30 "${vdb}-primary" "$db" "SELECT node_name, (SUM(file_size_bytes)/1048576)::NUMERIC(12,1) FROM v_monitor.depot_files GROUP BY 1;" 2>/dev/null || true)
  pods=$(vdb_pods_json "$vdb" | jq -r '.[] | "\(.status.podIP // "-")|\(.metadata.name)|\(.spec.nodeName // "-")"')
  printf '  %s%-22s %-8s %-11s %-8s %-18s %-28s %-15s %-5s %s%s\n' "$C_BOLD" "VERTICA NODE" "STATE" "SUBCLUSTER" "PRIMARY" "POD" "K8S NODE" "IP" "SESS" "DEPOT DATA MB" "$C_RESET"
  local name state addr sc prim pod knode s dp
  while IFS='|' read -r name state addr sc prim; do
    [[ -z $name ]] && continue
    pod=$(awk -F'|' -v ip="$addr" '$1==ip{print $2}' <<<"$pods"); knode=$(awk -F'|' -v ip="$addr" '$1==ip{print $3}' <<<"$pods")
    s=$(awk -F'|' -v n="$name" '$1==n{print $2}' <<<"$sess"); dp=$(awk -F'|' -v n="$name" '$1==n{print $2}' <<<"$depot")
    printf '  %-22s %s%*s %-11s %-8s %-18s %-28s %-15s %-5s %s\n' "$name" "$(color_state "$state")" $(( 8 - ${#state} > 0 ? 8 - ${#state} : 0 )) '' \
      "$sc" "$([[ $prim == t ]] && echo yes || echo no)" "${pod:--}" "${knode:--}" "$addr" "${s:-0}" "${dp:-0}"
  done <<<"$nodes"
  local sys; sys=$(vsql_t 30 "${vdb}-primary" "$db" "SELECT node_count||'|'||node_down_count||'|'||designed_fault_tolerance||'|'||current_fault_tolerance||'|'||current_epoch||'|'||ahm_epoch FROM system;" 2>/dev/null || true)
  IFS='|' read -r nc nd dk ck ce ae <<<"$sys"
  printf '  %sCluster:%s nodes=%s down=%s  K-safety designed=%s current=%s  epoch=%s AHM=%s\n' "$C_BOLD" "$C_RESET" "${nc:-?}" "${nd:-?}" "${dk:-?}" "${ck:-?}" "${ce:-?}" "${ae:-?}"
  local ver lic tabs; ver=$(vsql_t 30 "${vdb}-primary" "$db" "SELECT version();" 2>/dev/null | head -n1 || true)
  lic=$(vsql_t 30 "${vdb}-primary" "$db" "SELECT GET_COMPLIANCE_STATUS();" 2>/dev/null | tr '\n' ' ' | cut -c1-110 || true)
  tabs=$(vsql_t 30 "${vdb}-primary" "$db" "SELECT table_schema||'.'||table_name FROM tables WHERE table_schema IN ('lab','demo') ORDER BY 1;" 2>/dev/null | tr '\n' ' ' || true)
  printf '  %sVersion:%s %s\n  %sLicense:%s %s\n  %sLab/demo tables:%s %s\n' "$C_BOLD" "$C_RESET" "${ver:-?}" "$C_BOLD" "$C_RESET" "${lic:-?}" "$C_BOLD" "$C_RESET" "${tabs:-none}"
}
info_operator() {
  section "[4] VerticaDB operator — recent reconciliation events"
  local op; op=$(kc -n "$OP_NS" get pods --no-headers 2>/dev/null | grep -i verticadb-operator | awk '{print $1" ("$3", restarts "$4")"}' | head -n1 || true)
  printf '  %sOperator pod:%s %s   %sHelm chart:%s %s\n' "$C_BOLD" "$C_RESET" "${op:-not found}" "$C_BOLD" "$C_RESET" "$(state_get OPERATOR_CHART_VERSION_RESOLVED n/a)"
  kc -n "$NS" get events --field-selector involvedObject.kind=VerticaDB -o json 2>/dev/null \
    | jq -r '.items | sort_by(.lastTimestamp // .eventTime // .metadata.creationTimestamp) | .[-8:][] | [ ((.lastTimestamp // .eventTime // "") | sub("\\.[0-9]+";"") | sub("T";" ") | sub("Z";"")), .type, .involvedObject.name, .reason, (.message | gsub("\n";" ") | .[0:80]) ] | @tsv' \
    | while IFS=$'\t' read -r ts ty ob re ms; do
        local col=$C_CYAN; [[ $ty == Warning ]] && col=$C_YELLOW
        printf '  %s%s%s %s%-7s%s %-5s %s%-28s%s %s\n' "$C_DIM" "$ts" "$C_RESET" "$col" "$ty" "$C_RESET" "$ob" "$C_BOLD" "$re" "$C_RESET" "$ms"
      done || true
}
info_storage_usage() {
  section "[5] Storage and resource usage"
  kc -n "$NS" get pvc --no-headers 2>/dev/null | awk '{printf "  PVC %-34s %-6s %-8s %s\n", $1, $2, $4, $6}'
  kc -n "$MINIO_NS" get pvc --no-headers 2>/dev/null | awk '{printf "  PVC %-34s %-6s %-8s %s (MinIO communal storage)\n", $1, $2, $4, $6}'
  local top; top=$(kc -n "$NS" top pods --no-headers 2>/dev/null || true)
  if [[ -n $top ]]; then printf '  %s%-34s %-10s %s%s\n' "$C_BOLD" "POD" "CPU" "MEMORY" "$C_RESET"; awk '{printf "  %-34s %-10s %s\n", $1, $2, $3}' <<<"$top"
  else detail "kubectl top not available yet (metrics-server warming up)"; fi
  kv "Host RAM available" "$(( $(mem_kb MemAvailable) / 1048576 )) GB of $(( $(mem_kb MemTotal) / 1048576 )) GB"
}
do_info() {
  while :; do
    (( IS_TTY )) && [[ -n $INFO_WATCH ]] && printf '\033[H\033[2J'
    banner "VERTICA K8S LAB — LIVE INFO: pods / Vertica nodes / operator" "$(date '+%F %T') | read-only${INFO_WATCH:+ | refresh every ${INFO_WATCH}s — Ctrl+C to stop}"
    if [[ ! -f $STATE_FILE ]]; then warn "Lab not installed (no $STATE_FILE)."; return 0; fi
    if ! k8s_reachable; then
      warn "Kubernetes API not reachable — cluster stopped? Restart it with: sudo $SCRIPT_PATH --install"
      docker_ok && docker ps -a --filter "label=io.x-k8s.kind.cluster=$CLUSTER_NAME" --format '  {{.Names}}  {{.Status}}'
    else
      info_vdbs; info_pods; info_vertica_nodes "$VDB" "$DB_NAME"
      kc -n "$NS" get vdb "$VDBE" >/dev/null 2>&1 && info_vertica_nodes "$VDBE" "$DBE_NAME"
      info_operator; info_storage_usage
    fi
    [[ -z $INFO_WATCH ]] && break
    sleep "$INFO_WATCH"
  done
}

#==============================================================================
# --demo : drop/create a table, load a few rows, query them from the pods
#==============================================================================
vsql_in_pod() { # pod "SQL"  -> runs vsql INSIDE the Vertica server container
  local pod=$1 sql=$2 ip; ip=$(pod_ip "$pod")
  _log "SQL   [in-pod $pod] ${sql//$'\n'/ }"
  printf '%s\n%s\n' "$DB_PASSWORD" "$sql" | timeout 90 "${KC[@]}" exec -i -n "$NS" "$pod" -c server -- \
    sh -c 'IFS= read -r VSQL_PASSWORD; export VSQL_PASSWORD
           exec /opt/vertica/bin/vsql -m prefer -X -q -At -F " | " -v ON_ERROR_STOP=1 -h "$1" -d "$2" -U "$3"' sh "$ip" "$DB_NAME" "$DB_USER"
}
etl_job_probe() { # done when the Job succeeded or failed
  local j; j=$(kc -n "$NS" get job vlab-etl-job -o jsonpath='{.status.succeeded}/{.status.failed}' 2>/dev/null || true)
  printf 'job vlab-etl-job succeeded/failed: %s' "${j:-0/0}"; [[ $j == 1/* || $j == */1 ]]
}
# demo: a Kubernetes Job plays an ETL service that logs in with a JWT (no password anywhere in its spec)
demo_m2m_job() {
  step "Machine-to-machine login: an ETL job authenticates with a JWT, not a password"
  what "A Kubernetes Job gets a token from Keycloak (client_credentials) and queries Vertica as svc_etl over TLS."
  vsql_c "${VDB}-primary" "$DB_NAME" "GRANT USAGE ON SCHEMA demo TO svc_etl; GRANT SELECT ON demo.city_temps TO svc_etl;" >/dev/null
  cat >"$MANIFEST_DIR/etl-job.yaml" <<EOF
# ETL job for $LAB_TAG: its only credential is the OAuth client secret (Secret oauth-clients); it never sees a DB password
apiVersion: batch/v1
kind: Job
metadata: {name: vlab-etl-job, namespace: $NS, labels: {app: vlab-etl-job}}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    metadata: {labels: {app: vlab-etl-job, vertica-client: "true"}}
    spec:
      restartPolicy: Never
      nodeSelector: {node-role.kubernetes.io/control-plane: ""}
      tolerations:
      - {key: node-role.kubernetes.io/control-plane, operator: Exists, effect: NoSchedule}
      securityContext: {runAsUser: 5000, runAsGroup: 5000, runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}
      containers:
      - name: etl
        image: $(state_get VERTICA_IMAGE_RESOLVED)
        imagePullPolicy: IfNotPresent
        env:
        - {name: HOME, value: /tmp}
        - {name: CLIENT_ID, value: svc_etl}
        - name: CLIENT_SECRET
          valueFrom: {secretKeyRef: {name: oauth-clients, key: svc_etl}}
        command: ["sh", "-c"]
        args:
        - |
          set -e
          echo "1) requesting a token from the identity provider (grant_type=client_credentials)"
          VSQL_OAUTH_ACCESS_TOKEN=\$(curl -s -u "\$CLIENT_ID:\$CLIENT_SECRET" -d grant_type=client_credentials \\
            $IDP_ISSUER/protocol/openid-connect/token | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')
          export VSQL_OAUTH_ACCESS_TOKEN
          echo "   token received (\${#VSQL_OAUTH_ACCESS_TOKEN} characters, signed JWT; not printed)"
          echo "2) logging into Vertica with the token over TLS"
          vsql -X -m require -h ${VDB}-primary -d $DB_NAME -M oauth -U svc_etl -c \\
            "SELECT s.user_name AS db_user, s.authentication_method AS auth, s.ssl_state AS tls, c.country, COUNT(*) AS readings, ROUND(AVG(c.temp_c),1) AS avg_c FROM demo.city_temps c CROSS JOIN (SELECT user_name, authentication_method, ssl_state FROM sessions WHERE session_id = current_session()) s GROUP BY 1,2,3,4 ORDER BY avg_c DESC;"
        resources:
          requests: {cpu: 100m, memory: 128Mi}
          limits: {cpu: "1", memory: 512Mi}
        securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
EOF
  kc -n "$NS" delete job vlab-etl-job --ignore-not-found --wait=true >/dev/null 2>&1 || true
  run kc apply -f "$MANIFEST_DIR/etl-job.yaml"
  wait_until "ETL job finished" 180 3 etl_job_probe || true
  if [[ $(kc -n "$NS" get job vlab-etl-job -o jsonpath='{.status.succeeded}' 2>/dev/null) == 1 ]]; then
    run --show kc -n "$NS" logs job/vlab-etl-job
    ok "ETL job finished: authenticated with a JWT (OAuth 2.0 / JWT validation in Vertica) — no database password involved"
  else
    run --show --allow-fail kc -n "$NS" logs job/vlab-etl-job
    warn "ETL job did not complete — see the job log above"
  fi
  step_done
}
do_demo() {
  [[ $(state_get INSTALL_COMPLETE) == 1 ]] || die "Lab not installed. Run: sudo $SCRIPT_PATH --install"
  k8s_reachable || die "Kubernetes API not reachable — start the lab with: sudo $SCRIPT_PATH --install"
  banner "VERTICA ON KUBERNETES — SQL DEMO" "drop/create a table, load rows, query them in the Vertica pods | $(date '+%F %T')"
  STEP_TOTAL=8; [[ $(state_get OAUTH_INSTALLED) == 1 ]] && STEP_TOTAL=9
  local H="${VDB}-primary"
  step "Where the database runs"
  what "Each Vertica node is a pod of the StatefulSet ${VDB}-primary, scheduled on a different Kubernetes worker."
  wait_until "SQL client pod ready" 300 5 client_probe || die "Client pod not ready"
  wait_db_ready "$VDB" "$DB_NAME" 3 600 "Database $DB_NAME ready" || die "Database not ready (see --info)"
  run --show kc -n "$NS" get pods -l "vertica-lab/db=$VDB" -o wide
  step_done

  step "Drop and (re)create a table"
  what "DROP TABLE IF EXISTS + CREATE TABLE in schema 'demo', segmented across all nodes by HASH(id)."
  vsql_show "$H" "$DB_NAME" "DDL" "
CREATE SCHEMA IF NOT EXISTS demo;
DROP TABLE IF EXISTS demo.city_temps CASCADE;
CREATE TABLE demo.city_temps (
  id INT NOT NULL, city VARCHAR(30), country VARCHAR(20), reading_ts TIMESTAMP, temp_c NUMERIC(5,1)
) ORDER BY id SEGMENTED BY HASH(id) ALL NODES;
SELECT column_name, data_type FROM columns WHERE table_schema='demo' AND table_name='city_temps' ORDER BY ordinal_position;" \
    || die "DDL failed"
  ok "Table demo.city_temps created"
  step_done

  step "Load a few rows"
  what "INSERT 10 rows with one multi-row INSERT and COMMIT (Eon Mode writes ROS files and uploads them to communal S3)."
  vsql_show "$H" "$DB_NAME" "INSERT + COMMIT" "
INSERT INTO demo.city_temps (id, city, country, reading_ts, temp_c)
SELECT id, city, country, ts::TIMESTAMP, t::NUMERIC(5,1) FROM (
          SELECT 1 AS id,'Tel Aviv' AS city,'Israel' AS country,'2026-11-03 08:00:00' AS ts,24.5 AS t
UNION ALL SELECT 2,'Jerusalem','Israel','2026-11-03 08:00:00',19.0
UNION ALL SELECT 3,'Haifa','Israel','2026-11-03 08:00:00',22.1
UNION ALL SELECT 4,'London','UK','2026-11-03 08:00:00',11.2
UNION ALL SELECT 5,'New York','USA','2026-11-03 08:00:00',9.8
UNION ALL SELECT 6,'Tokyo','Japan','2026-11-03 08:00:00',16.4
UNION ALL SELECT 7,'Sydney','Australia','2026-11-03 08:00:00',21.7
UNION ALL SELECT 8,'Tel Aviv','Israel','2026-11-03 14:00:00',26.0
UNION ALL SELECT 9,'London','UK','2026-11-03 14:00:00',13.0
UNION ALL SELECT 10,'Tokyo','Japan','2026-11-03 14:00:00',18.9
) AS r;
COMMIT;
SELECT COUNT(*) AS rows_loaded FROM demo.city_temps;" || die "INSERT failed"
  step_done

  step "Query the rows"
  vsql_show "$H" "$DB_NAME" "All rows" "SELECT id, city, country, reading_ts, temp_c FROM demo.city_temps ORDER BY id;" || true
  vsql_show "$H" "$DB_NAME" "Aggregation per country" \
    "SELECT country, COUNT(*) AS readings, MIN(temp_c) AS min_c, MAX(temp_c) AS max_c, ROUND(AVG(temp_c),1) AS avg_c FROM demo.city_temps GROUP BY country ORDER BY avg_c DESC;" || true
  vsql_show "$H" "$DB_NAME" "Window function: change between readings per city" \
    "SELECT city, reading_ts, temp_c, temp_c - LAG(temp_c) OVER (PARTITION BY city ORDER BY reading_ts) AS delta_c FROM demo.city_temps WHERE city IN ('Tel Aviv','London','Tokyo') ORDER BY city, reading_ts;" || true
  step_done

  step "Where the rows are physically stored"
  what "Rows are hash-segmented over the nodes; in Eon Mode the files also live in communal storage (MinIO)."
  vsql_show "$H" "$DB_NAME" "Rows per Vertica node" \
    "SELECT node_name, SUM(row_count) AS rows_on_node FROM projection_storage WHERE anchor_table_schema='demo' AND anchor_table_name='city_temps' GROUP BY 1 ORDER BY 1;" || true
  step_done

  step "Same query executed INSIDE every Vertica pod"
  what "kubectl exec into each pod's 'server' container and run vsql there — every node sees the full table."
  local p knode out
  for p in $(vdb_pods_json "$VDB" | jq -r '.[].metadata.name' | sort); do
    knode=$(pod_node "$p")
    printf '    %s$ kubectl exec -n %s %s -c server -- vsql -c "SELECT local_node_name(), COUNT(*), AVG(temp_c) FROM demo.city_temps"%s\n' "$C_DIM" "$NS" "$p" "$C_RESET"
    if out=$(vsql_in_pod "$p" "SELECT local_node_name(), COUNT(*), ROUND(AVG(temp_c),1) FROM demo.city_temps;" 2>&1); then
      ok "pod ${C_BOLD}$p${C_RESET} (k8s node $knode) -> $out"
    else warn "pod $p: query failed: ${out:0:160}"; fi
  done
  step_done

  step "External access from the workstation (host vsql -> NodePort 127.0.0.1:$HOST_PORT_PRIMARY)"
  if [[ -x /opt/vertica/bin/vsql ]]; then
    what "Uses the host's existing /opt/vertica/bin/vsql binary read-only; it connects to the Kubernetes DB, not to the host DB."
    printf '    %s$ /opt/vertica/bin/vsql -m prefer -h 127.0.0.1 -p %s -U %s -d %s -c "SELECT ..."%s\n' "$C_DIM" "$HOST_PORT_PRIMARY" "$DB_USER" "$DB_NAME" "$C_RESET"
    if out=$(VSQL_PASSWORD="$DB_PASSWORD" timeout 60 /opt/vertica/bin/vsql -m prefer -X -q -h 127.0.0.1 -p "$HOST_PORT_PRIMARY" -U "$DB_USER" -d "$DB_NAME" \
              -c "SELECT local_node_name() AS served_by, COUNT(*) AS rows, MAX(temp_c) AS hottest FROM demo.city_temps;" 2>&1); then
      while IFS= read -r l; do printf '      %s%s%s %s\n' "$C_DIM" "$U_VL" "$C_RESET" "$l"; done <<<"$out"
      ok "Workstation -> Kubernetes NodePort -> Vertica pod works"
    else warn "Host vsql connection failed: ${out:0:200}"; fi
  else info "No /opt/vertica/bin/vsql on the host — skipped"; fi
  step_done

  [[ $(state_get OAUTH_INSTALLED) == 1 ]] && demo_m2m_job
  step "Try it yourself"
  detail "Interactive vsql inside a pod:"
  detail "  sudo $BIN_DIR/kubectl --kubeconfig $KUBECONFIG_FILE -n $NS exec -it ${VDB}-primary-0 -c server -- /opt/vertica/bin/vsql -U $DB_USER -d $DB_NAME"
  detail "From the workstation:   /opt/vertica/bin/vsql -m prefer -h 127.0.0.1 -p $HOST_PORT_PRIMARY -U $DB_USER -d $DB_NAME"
  detail "Password:          sudo grep DB_PASSWORD $SECRETS_FILE | cut -d= -f2"
  detail "The table demo.city_temps is kept; re-running --demo drops and recreates it."
  step_done
  banner "DEMO COMPLETE" "Live view: sudo $SCRIPT_PATH --info --watch 5"
}

#==============================================================================
# --cleanup
#==============================================================================
do_cleanup() {
  banner "VERTICA K8S LAB — CLEANUP" "$(date '+%F %T') | log: $LOG_FILE"
  STEP_TOTAL=9
  info "Will REMOVE (only objects created by this script):"
  detail "kind cluster '$CLUSTER_NAME' and its node containers: $(lab_containers 2>/dev/null | tr '\n' ' ')"
  detail "all Kubernetes objects inside it (VerticaDBs, pods, PVCs, services, CRDs, Helm release, MinIO)"
  detail "Docker network $DOCKER_NET, kind volumes, images pulled by the lab:"
  if [[ -f $STATE_DIR/lab-images.txt ]]; then while IFS= read -r i; do grep -qxF -- "$i" "$STATE_DIR/preexisting-images.txt" 2>/dev/null || detail "   - $i"; done <"$STATE_DIR/lab-images.txt"; fi
  [[ $(state_get DOCKER_INSTALLED_BY_LAB) == 1 ]] && detail "Docker engine packages installed by the lab: $(tr '\n' ' ' <"$STATE_DIR/apt-installed.txt" 2>/dev/null)"
  [[ -s $STATE_DIR/apt-installed.txt && $(state_get DOCKER_INSTALLED_BY_LAB) != 1 ]] && detail "apt packages installed by the lab: $(tr '\n' ' ' <"$STATE_DIR/apt-installed.txt")"
  detail "runtime kernel settings raised by the lab (restored), and $LAB_DIR/{${LAB_SUBDIRS[*]}}"
  info "Will KEEP: host Vertica (/opt/vertica, dbadmin, its DB/ports/units), pre-existing Docker/images/networks,"
  detail "this script ($SCRIPT_PATH) and any license file you placed in $LAB_DIR"
  confirm "Proceed with cleanup?" || die "Cleanup cancelled."

  step "Stop lab background processes"
  local p; p=$(pgrep -f "$BIN_DIR/" 2>/dev/null | grep -vx "$$" || true)
  if [[ -n $p ]]; then run --allow-fail kill $p; else ok "No lab background processes"; fi
  step_done

  step "Delete Kubernetes resources (VerticaDBs, Helm release, CRDs)"
  if k8s_reachable; then
    local c; for c in $(lab_containers); do [[ $(docker inspect -f '{{.State.Status}}' "$c") == paused ]] && docker unpause "$c" >/dev/null 2>&1 || true; done
    run --allow-fail timeout 300 "${KC[@]}" delete vdb --all -A --wait=true --timeout=240s
    run --allow-fail timeout 120 "${KC[@]}" delete vrpq --all -A --wait=false
    [[ -x $BIN_DIR/helm ]] && run --allow-fail hm uninstall "$OP_RELEASE" -n "$OP_NS" --wait --timeout 3m
    local crds; crds=$(kc get crd -o name 2>/dev/null | grep -E '\.vertica\.com$' || true)
    [[ -n $crds ]] && run --allow-fail timeout 180 "${KC[@]}" delete $crds --wait=false
    ok "Kubernetes objects removed (the cluster itself is deleted next)"
  else info "Kubernetes API not reachable — the cluster deletion below removes everything anyway"; fi
  step_done

  step "Delete the kind cluster and its containers, volumes and network"
  record_lab_volumes 2>/dev/null || true
  if [[ -x $BIN_DIR/kind ]] && docker_ok; then run --allow-fail kd delete cluster --name "$CLUSTER_NAME" --kubeconfig "$KUBECONFIG_FILE"; fi
  if docker_ok; then
    local left; left=$(docker ps -aq --filter "label=io.x-k8s.kind.cluster=$CLUSTER_NAME")
    [[ -n $left ]] && run --allow-fail docker rm -f -v $left
    if [[ -f $STATE_DIR/lab-volumes.txt ]]; then
      local v; while IFS= read -r v; do if docker volume inspect "$v" >/dev/null 2>&1; then run --allow-fail docker volume rm "$v"; fi; done <"$STATE_DIR/lab-volumes.txt"
    fi
    if docker network inspect "$DOCKER_NET" >/dev/null 2>&1; then
      if [[ $(state_get DOCKER_NET_PREEXISTED 0) == 1 ]]; then info "Network $DOCKER_NET pre-existed — kept"; else run --allow-fail docker network rm "$DOCKER_NET"; fi
    fi
    ok "kind cluster, node containers, volumes and network removed"
  fi
  step_done

  step "Remove container images pulled by the lab (pre-existing images are preserved)"
  if docker_ok && [[ -f $STATE_DIR/lab-images.txt ]]; then
    local img; while IFS= read -r img; do
      [[ -z $img ]] && continue
      if grep -qxF -- "$img" "$STATE_DIR/preexisting-images.txt" 2>/dev/null; then info "Keeping pre-existing image $img"; continue; fi
      if image_present "$img"; then run --allow-fail docker rmi "$img"; fi
    done <"$STATE_DIR/lab-images.txt"
    if [[ $(state_get OPERATOR_IMAGE) != "" ]] && image_present "$(state_get OPERATOR_IMAGE)" && ! grep -qxF -- "$(state_get OPERATOR_IMAGE)" "$STATE_DIR/preexisting-images.txt"; then run --allow-fail docker rmi "$(state_get OPERATOR_IMAGE)"; fi
  else ok "No lab image list (nothing to remove)"; fi
  step_done

  step "Restore kernel runtime parameters"
  local k key orig set cur
  for k in fs.inotify.max_user_watches fs.inotify.max_user_instances vm.max_map_count; do
    key="SYSCTL_${k//./_}"; orig=$(state_get "${key}_ORIG"); set=$(state_get "${key}_SET")
    if [[ -n $orig ]]; then
      cur=$(sysctl -n "$k"); if [[ $cur == "$set" ]]; then run sysctl -w "$k=$orig"; ok "$k restored to $orig"; else info "$k changed by someone else ($cur) — left as is"; fi
    else ok "$k was not changed by the lab"; fi
  done
  step_done

  step "Docker engine (only if installed by the lab)"
  if [[ $(state_get DOCKER_INSTALLED_BY_LAB) == 1 ]]; then
    run --allow-fail systemctl disable --now docker.socket docker.service containerd.service
    local pk; pk=$(tr '\n' ' ' <"$STATE_DIR/apt-installed.txt" 2>/dev/null || true)
    if [[ -n $pk ]]; then
      local sim extra; sim=$(apt-get -s purge $pk 2>/dev/null | awk '/^Purg /{print $2}' | sort -u)
      extra=$(set_minus "$sim" "$(tr ' ' '\n' <<<"$pk")" | tr '\n' ' ')
      if [[ -n ${extra// /} ]]; then warn "Purging would also remove packages not installed by the lab ($extra) — skipping package removal for safety."
      else run env DEBIAN_FRONTEND=noninteractive apt-get purge -y $pk; fi
    fi
    local d; for d in /var/lib/docker /var/lib/containerd /etc/docker /run/docker; do
      grep -qxF "$d" "$STATE_DIR/preexisting-paths.txt" 2>/dev/null && continue
      if [[ -e $d ]]; then run --allow-fail rm -rf "$d"; fi
    done
    [[ $(state_get DOCKER_GROUP_PREEXISTED) == 0 ]] && getent group docker >/dev/null && run --allow-fail groupdel docker
    ok "Docker removed (it was installed by the lab)"
  else
    if [[ $(state_get DOCKER_WAS_STOPPED) == 1 ]]; then run --allow-fail systemctl stop docker; ok "Pre-existing Docker stopped again (it was stopped before the lab)"
    else ok "Pre-existing Docker left exactly as configured (not disabled, not removed)"; fi
    if [[ -s $STATE_DIR/apt-installed.txt ]]; then
      local pk2; pk2=$(tr '\n' ' ' <"$STATE_DIR/apt-installed.txt")
      local sim2 extra2; sim2=$(apt-get -s purge $pk2 2>/dev/null | awk '/^Purg /{print $2}' | sort -u)
      extra2=$(set_minus "$sim2" "$(tr ' ' '\n' <<<"$pk2")" | tr '\n' ' ')
      if [[ -n ${extra2// /} ]]; then warn "Skipping purge of $pk2 (would remove other packages: $extra2)"
      else run --allow-fail env DEBIAN_FRONTEND=noninteractive apt-get purge -y $pk2; fi
    fi
  fi
  [[ $(state_get ROOT_DOCKER_DIR_PREEXISTED) == 0 && -d /root/.docker ]] && run --allow-fail rm -rf /root/.docker
  step_done

  step "Remove lab files (tools, manifests, downloads, caches)"
  local d
  for d in bin manifests downloads cache tmp; do
    if [[ -e $LAB_DIR/$d ]]; then rm -rf "${LAB_DIR:?}/$d"; fi
  done
  ok "Removed $LAB_DIR/{bin,manifests,downloads,cache,tmp}; state/logs are removed after the audit"
  step_done

  step "Verify nothing remains and nothing will start after reboot"
  local vrc=0; do_verify_clean || vrc=$?
  step_done

  step "Finish: remove state (credentials) and, unless --keep-logs, logs and reports"
  rm -rf "${LAB_DIR:?}/state"; ok "Removed $LAB_DIR/state (generated passwords, kubeconfig, tracking lists)"
  if $KEEP_LOGS; then
    ok "Logs kept in $LOG_DIR and reports in $REPORT_DIR (--keep-logs)"
  else
    LOG_FILE=""; rm -rf "${LAB_DIR:?}/logs" "${LAB_DIR:?}/reports"
    ok "Logs and reports removed (use --keep-logs to keep them)"
  fi
  info "Left in $LAB_DIR: $(ls -A "$LAB_DIR" 2>/dev/null | tr '\n' ' ') (your script / license only)"
  info "Reboot test:  sudo reboot   then:  sudo $SCRIPT_PATH --verify-clean"
  (( vrc == 0 )) && banner "CLEANUP COMPLETE — no lab resources remain" || banner "CLEANUP FINISHED WITH RESIDUE — see FAIL lines above"
  return $vrc
}

#==============================================================================
# --verify-clean  (read-only residue audit; also run after reboot)
#==============================================================================
do_verify_clean() {
  local fails=0
  hash -r 2>/dev/null || true   # forget cached command paths (binaries may have just been purged)
  vc_pass() { printf '    %s%s PASS%s %s\n' "$C_GREEN$C_BOLD" "$U_OK" "$C_RESET" "$*"; _log "VERIFY PASS $*"; }
  vc_fail() { printf '    %s%s FAIL%s %s\n' "$C_RED$C_BOLD" "$U_FAIL" "$C_RESET" "$*"; _log "VERIFY FAIL $*"; fails=$((fails + 1)); }
  vc_info() { printf '    %s%s%s %s\n' "$C_BLUE" "$U_INFO" "$C_RESET" "$*"; }
  [[ $MODE == verify-clean ]] && banner "VERTICA K8S LAB — RESIDUE / REBOOT-SAFETY AUDIT" "$(date '+%F %T') | uptime: $(uptime -p 2>/dev/null || true)"
  if have docker; then
    if docker info >/dev/null 2>&1; then
      local c; c=$(docker ps -aq --filter "label=io.x-k8s.kind.cluster=$CLUSTER_NAME" | wc -l)
      (( c == 0 )) && vc_pass "No kind node containers for '$CLUSTER_NAME' (running or stopped)" || vc_fail "$c lab containers still exist"
      local n; n=$(docker ps -a --format '{{.Names}}' | grep -c "^$CLUSTER_NAME-" || true)
      (( n == 0 )) && vc_pass "No containers named $CLUSTER_NAME-*" || vc_fail "$n containers named $CLUSTER_NAME-*"
      docker network inspect "$DOCKER_NET" >/dev/null 2>&1 && vc_fail "Docker network $DOCKER_NET exists" || vc_pass "Docker network $DOCKER_NET absent"
      if [[ -f $STATE_DIR/lab-volumes.txt ]]; then
        local lv=0 v; while IFS= read -r v; do if docker volume inspect "$v" >/dev/null 2>&1; then lv=$((lv+1)); fi; done <"$STATE_DIR/lab-volumes.txt"
        (( lv == 0 )) && vc_pass "Lab volumes removed" || vc_fail "$lv lab volumes remain"
      fi
      local imgs; imgs=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^(opentext/vertica-k8s|opentext/verticadb-operator|kindest/node|quay.io/minio/minio|minio/minio|cgr.dev/chainguard/minio):' || true)
      if [[ -n $imgs ]]; then
        if [[ -f $STATE_DIR/preexisting-images.txt ]] && [[ -z $(set_minus "$imgs" "$(cat "$STATE_DIR/preexisting-images.txt")") ]]; then vc_pass "Only pre-existing lab-type images remain: ${imgs//$'\n'/ }"
        else vc_info "Lab-type images present (pre-existing or not tracked): ${imgs//$'\n'/ }"; fi
      else vc_pass "No lab images (vertica-k8s, verticadb-operator, kindest/node, minio) present"; fi
      local rp; rp=$(docker ps -aq | xargs -r docker inspect -f '{{.Name}} {{.HostConfig.RestartPolicy.Name}}' 2>/dev/null | grep -E "/$CLUSTER_NAME-" || true)
      [[ -z $rp ]] && vc_pass "No lab container has a restart policy that could start it at boot" || vc_fail "Restartable lab containers: $rp"
    else vc_info "Docker CLI present but daemon not running (pre-existing Docker stopped, or not started at boot)"; fi
    if [[ $(state_get DOCKER_INSTALLED_BY_LAB) == 1 ]]; then
      systemctl is-enabled docker.service >/dev/null 2>&1 && vc_fail "Lab-installed docker.service is enabled at boot" || vc_pass "Lab-installed Docker is not enabled at boot"
    else vc_info "Docker is pre-existing (or not installed by the lab) — its boot setting is the owner's: $(systemctl is-enabled docker.service 2>/dev/null || echo n/a)"; fi
  else vc_pass "Docker not installed (the lab's Docker, if any, was removed)"; fi
  local procs; procs=$(pgrep -af "$BIN_DIR/(kind|kubectl|helm)|kindest|$CLUSTER_NAME" 2>/dev/null | grep -v -e "$$" -e pgrep -e "$SCRIPT_NAME" || true)
  [[ -z $procs ]] && vc_pass "No lab processes (kind/kubectl/helm/kubelet of the lab) running" || vc_fail "Lab processes running: $procs"
  local units; units=$(systemctl list-unit-files --no-legend 2>/dev/null | grep -Ei "$LAB_TAG|$CLUSTER_NAME|kind-|k3s|minikube" || true)
  [[ -z $units ]] && vc_pass "No systemd units created by the lab" || vc_fail "Suspicious systemd units: $units"
  local cron; cron=$( (crontab -l 2>/dev/null; cat /etc/crontab /etc/cron.d/* 2>/dev/null) | grep -E "$LAB_TAG|$SCRIPT_NAME" || true)
  [[ -z $cron ]] && vc_pass "No cron entries referencing the lab" || vc_fail "Cron entries found: $cron"
  local sysd; sysd=$(grep -rlE "$LAB_TAG|vertica-lab" /etc/sysctl.conf /etc/sysctl.d 2>/dev/null || true)
  [[ -z $sysd ]] && vc_pass "No persistent sysctl configuration written by the lab" || vc_fail "Persistent sysctl files: $sysd"
  local p bad=0; for p in "$HOST_PORT_PRIMARY" "$HOST_PORT_SECONDARY"; do if port_in_use "$p"; then bad=1; fi; done
  (( bad == 0 )) && vc_pass "Lab ports $HOST_PORT_PRIMARY/$HOST_PORT_SECONDARY are not listening" || vc_fail "A lab port is still listening"
  local residue=""; for p in bin manifests downloads cache tmp; do if [[ -e $LAB_DIR/$p ]]; then residue+="$p "; fi; done
  if [[ $MODE == verify-clean ]]; then [[ -e $LAB_DIR/state ]] && residue+="state "; fi
  if [[ -z $residue ]]; then vc_pass "Lab working directories removed from $LAB_DIR"
  elif [[ $MODE == cleanup ]]; then vc_info "Remaining during cleanup: $residue"
  else vc_fail "Remaining lab directories in $LAB_DIR: $residue"; fi
  [[ -e /root/.kube/config ]] && grep -q "kind-$CLUSTER_NAME" /root/.kube/config 2>/dev/null && vc_fail "/root/.kube/config references the lab cluster" || vc_pass "No lab context in /root/.kube/config"
  vc_info "Host Vertica (read-only): $(host_vertica_snapshot | tr '\n' ' ')"
  vc_info "Kernel values now: vm.max_map_count=$(sysctl -n vm.max_map_count) fs.inotify.max_user_watches=$(sysctl -n fs.inotify.max_user_watches) (runtime values reset at reboot)"
  if (( fails == 0 )); then printf '\n    %s%s RESULT: CLEAN — nothing from the lab is running or configured to start at boot.%s\n' "$C_GREEN$C_BOLD" "$U_OK" "$C_RESET"; return 0
  else printf '\n    %s%s RESULT: %d residue item(s) found.%s\n' "$C_RED$C_BOLD" "$U_FAIL" "$fails" "$C_RESET"; return 1; fi
}

#==============================================================================
# CLI
#==============================================================================
usage() {
  cat <<EOF
$SCRIPT_NAME $SCRIPT_VERSION — Vertica Kubernetes Operator $VERTICA_TARGET_VERSION single-workstation lab

Run as your sudo-capable admin user (NOT dbadmin) from $LAB_DIR:
  sudo $LAB_DIR/$SCRIPT_NAME --install        build kind cluster + MinIO + operator + 3-node Eon DB
  sudo $LAB_DIR/$SCRIPT_NAME --test           run the production-readiness test suite (PASS/FAIL report)
  sudo $LAB_DIR/$SCRIPT_NAME --status         read-only status dashboard (install state, host, Docker, K8s, DB)
  sudo $LAB_DIR/$SCRIPT_NAME --info [--watch N]  live view: VerticaDB CRs, pods, Vertica nodes<->pods, operator events
  sudo $LAB_DIR/$SCRIPT_NAME --demo           drop/create a table, load 10 rows, query them inside every Vertica pod
  sudo $LAB_DIR/$SCRIPT_NAME --cleanup        remove everything the script created (asks for 'yes')
  sudo $LAB_DIR/$SCRIPT_NAME --verify-clean   residue / reboot-safety audit (run after a reboot)

Typical workflow (copy/paste):
  cd $LAB_DIR
  sudo ./$SCRIPT_NAME --install                # ~4-10 min; re-running it is safe (idempotent, resumes)
  sudo ./$SCRIPT_NAME --demo                   # running it again is fine: it drops and recreates the table
  sudo ./$SCRIPT_NAME --info --watch 5         # Ctrl-C to stop
  sudo ./$SCRIPT_NAME --test                   # 14 tests, ~10-15 min (or: --test --only selfheal,nodefail)
  sudo ./$SCRIPT_NAME --cleanup                # removes only what the lab created (asks 'yes')
  sudo reboot
  sudo ./$SCRIPT_NAME --verify-clean           # residue / reboot-safety audit

Options:
  --license FILE     Vertica license file (default: $LAB_DIR/vertica_license.dat if present)
  --only g1,g2       run only these test groups      --skip g1,g2   skip these test groups
                     groups: health workload perf storage monitoring security m2m isolation
                             reconcile selfheal nodefail backup scaling final
  --yes              non-interactive (no confirmation prompt for --cleanup)
  --keep-logs        keep logs/ and reports/ during --cleanup
  --no-color         disable ANSI colours
  -h, --help         this help

Features (environment variables, set at --install):
  ENABLE_INTERNODE_TLS=$ENABLE_INTERNODE_TLS   TLS between the Vertica nodes (data channel, VERIFY_CA)
  ENABLE_OAUTH=$ENABLE_OAUTH           Keycloak + OAuth 2.0 / JWT machine-to-machine database login (T07, demo)

Test timing (environment variables, e.g. sudo LOAD_SECONDS=90 ./$SCRIPT_NAME --test):
  LOAD_SECONDS=$LOAD_SECONDS        client load (1 query/s) during the failure tests T10-T12
  RECOVERY_TIMEOUT=$RECOVERY_TIMEOUT    time cap for every self-healing / recovery wait
  NODE_FAIL_SECONDS=$NODE_FAIL_SECONDS   how long the worker stays frozen in T12
  SCALE_TIMEOUT=$SCALE_TIMEOUT       time cap for each scaling step in T14

Files: tools $BIN_DIR | state $STATE_DIR | logs $LOG_DIR | reports $REPORT_DIR
EOF
}
parse_args() {
  while (($#)); do
    case $1 in
      --install|--test|--status|--info|--demo|--cleanup|--verify-clean)
        [[ -n $MODE ]] && { echo "Only one mode option (--install/--test/--status/--info/--demo/--cleanup/--verify-clean) allowed" >&2; exit 2; }
        MODE=${1#--} ;;
      --watch) [[ $# -ge 2 && $2 =~ ^[0-9]+$ && $2 -ge 2 ]] || { echo "--watch needs seconds (>=2)" >&2; exit 2; }; INFO_WATCH=$2; shift ;;
      --yes|-y) ASSUME_YES=true ;;
      --keep-logs) KEEP_LOGS=true ;;
      --only) [[ $# -ge 2 ]] || { echo "--only needs a value" >&2; exit 2; }; ONLY_GROUPS=$2; shift ;;
      --skip) [[ $# -ge 2 ]] || { echo "--skip needs a value" >&2; exit 2; }; SKIP_GROUPS=$2; shift ;;
      --license) [[ $# -ge 2 ]] || { echo "--license needs a file" >&2; exit 2; }; VERTICA_LICENSE_FILE=$(readlink -f "$2"); shift ;;
      --no-color) NO_COLOR=1 ;;
      -h|--help) MODE=help ;;
      *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
    shift
  done
}
main() {
  setup_ui            # defaults (so early exits can still print safely)
  parse_args "$@"
  setup_ui            # re-apply after --no-color
  init_host_ip_mask   # never print/log the workstation's own IP addresses
  # later runs (--test/--demo/--status) report the version that was actually installed
  if [[ -z $TARGET_FROM_ENV && -r $STATE_FILE ]]; then
    local tv; tv=$(state_get TARGET_VERSION); if [[ -n $tv ]]; then VERTICA_TARGET_VERSION=$tv; fi
  fi
  case $MODE in
    install) require_root; init_runtime install; do_install ;;
    test)    require_root; init_runtime test; do_test; exit "$TEST_EXIT" ;;   # failed tests are reported, not "unexpected"
    status)  require_root; TMPDIR_LAB=${TMPDIR:-/tmp}; load_secrets; do_status ;;
    info)    require_root; TMPDIR_LAB=${TMPDIR:-/tmp}; load_secrets; do_info ;;
    demo)    require_root; init_runtime demo; do_demo ;;
    cleanup) require_root; init_runtime cleanup; do_cleanup ;;
    verify-clean) require_root; do_verify_clean ;;
    help) usage ;;
    *) usage; exit 2 ;;
  esac
}
main "$@"
