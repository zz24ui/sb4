#!/bin/sh

set -eu

SING_BOX_VERSION=""
SERVICE_NAME=sing-box

# Files this script owns carry the marker, so a service created by another
# install (or by a distro package) is never stopped, overwritten or removed.
SCRIPT_TAG="sb-anytls-ipv4.sh"
UNIT_MARKER="# Managed by $SCRIPT_TAG"
SYSTEMD_UNIT="/etc/systemd/system/${SERVICE_NAME}.service"
INITD_FILE="/etc/init.d/$SERVICE_NAME"

VLESS_PORT=57351
HY2_PORT=57353
ANYTLS_PORT=57355

VLESS_UUID=""
REALITY_PRIVATE=""
REALITY_PUBLIC=""
REALITY_SHORT_ID=""
HY2_PASSWORD=""
ANYTLS_PASSWORD=""

SNI=www.tencentcloud.com
REALITY_DEST_PORT=443

BASE_DIR="${SING_BOX_HOME:-/root/sing-box}"
BIN_PATH="$BASE_DIR/sing-box"

CONF_DIR="$BASE_DIR/conf"
LOG_DIR="$BASE_DIR/logs"
LOG_FILE="$LOG_DIR/sing-box.log"
PID_FILE="$BASE_DIR/sing-box.pid"
ROTATOR_PID_FILE="$BASE_DIR/log-rotator.pid"

LOG_MAX_BYTES=$((10 * 1024 * 1024))
LOG_KEEP_BYTES=$((5 * 1024 * 1024))

CONF_FILE="$CONF_DIR/config.json"
REALITY_PUBLIC_FILE="$CONF_DIR/reality-public.key"
TLS_CERT_FILE="$CONF_DIR/tls-cert.pem"
TLS_KEY_FILE="$CONF_DIR/tls-key.pem"
CLIENT_FILES="clash-pc.yaml clash-mobile.yaml singbox-pc.json singbox-android.json singbox-ios.json egern.yaml"
# Older installs kept the client configs in this folder.
OLD_CLIENT_DIR="$BASE_DIR/client"

# Left unbounded, the Go heap and socket buffers can crowd out the page cache that
# holds sing-box's own large binary, and the kernel then thrashes and OOM-kills it.
# 4 MiB per socket carries about 250 Mbit/s on one TCP connection at 90 ms. At 8 MiB,
# a dozen busy sockets took 90 MiB and got sing-box OOM-killed in a 128 MB container.
GO_MEMORY_LIMIT=48MiB
TCP_BUFFER_MAX=4194304

SERVER=""
SERVER_IPV4=""

if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
  C_RESET=$(printf '\033[0m'); C_OK=$(printf '\033[32m')
  C_ERR=$(printf '\033[31m'); C_INFO=$(printf '\033[36m')
  C_BOLD=$(printf '\033[1m')
else
  C_RESET=''; C_OK=''; C_ERR=''; C_INFO=''; C_BOLD=''
fi

log()  { printf '%s==>%s %s\n' "$C_INFO" "$C_RESET" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_OK" "$C_RESET" "$*"; }
warn() { printf '%s  !!%s %s\n' "$C_ERR" "$C_RESET" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_ERR" "$C_RESET" "$*" >&2; exit 1; }

usage() {
  cat << 'USAGE'
IPv4-only sing-box installer for Alpine Linux and Debian/Ubuntu.

Installs sing-box and starts three inbounds with random credentials:
  * VLESS + REALITY (XTLS-Vision)  on 57351/tcp
  * Hysteria2                      on 57353/udp
  * AnyTLS                         on 57355/tcp

Usage:
  ./sb-anytls-ipv4.sh              install (or repair) and start
  ./sb-anytls-ipv4.sh --show       print the share links for an existing install
  ./sb-anytls-ipv4.sh --client-config
                        write Clash, sing-box and Egern client configs
  ./sb-anytls-ipv4.sh --uninstall  stop and remove everything this script created

Client configs send China and LAN traffic direct and everything else through
the proxy, with 223.5.5.5 as DNS. They contain credentials and are written to
the state directory; an install rewrites them.

IPv6 is disabled end to end: inbounds listen on 0.0.0.0 only, DNS answers A
records only, the client configs build no IPv6 addresses and the sing-box
clients reject IPv6 destinations. A client host with working IPv6 should also
turn IPv6 off itself, since the tunnel carries no IPv6 routes.
Clients must reach this server over IPv4.

Client configs need sing-box 1.14.0+ (http_clients, DNS evaluate) and mihomo
1.19.0+ (anytls). Older clients cannot import them.

Always installs the latest stable sing-box release; re-running upgrades it.
REALITY, Hysteria2 and AnyTLS all use www.tencentcloud.com as the SNI.
Hysteria2 and AnyTLS use a self-signed certificate; clients skip verification.
Re-running keeps the existing credentials; --uninstall removes them.

State lives under /root/sing-box (binary, config, logs, pids).
Set SING_BOX_HOME to put it somewhere else.

Supports both systemd (Debian/Ubuntu) and OpenRC (Alpine); falls back to a
background process when neither init is present (e.g. inside a container).
sing-box is restarted automatically if it exits or is killed (e.g. by OOM).
USAGE
}

MODE=install
case "${1:-}" in
  ""|--install)         MODE=install ;;
  --show)               MODE=show ;;
  --client-config)      MODE=client-config ;;
  --uninstall|--remove) MODE=uninstall ;;
  -h|--help)            usage; exit 0 ;;
  *) die "unknown option: $1 (try --show, --client-config or --uninstall)" ;;
esac

case "$MODE" in
  show|client-config) ;;
  *) [ "$(id -u)" -eq 0 ] || die "must run as root (try: sudo $0)" ;;
esac

DISTRO=unknown
if [ -r /etc/os-release ]; then
  DISTRO=$(. /etc/os-release && printf '%s' "${ID:-unknown}")
fi
case "$DISTRO" in
  alpine)                 DISTRO_FAMILY=alpine ;;
  debian|ubuntu|raspbian) DISTRO_FAMILY=debian ;;
  *)
    if command -v apk >/dev/null 2>&1; then DISTRO_FAMILY=alpine
    elif command -v apt-get >/dev/null 2>&1; then DISTRO_FAMILY=debian
    else DISTRO_FAMILY=unknown; fi
    ;;
esac

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  INIT=systemd
elif command -v rc-update >/dev/null 2>&1 && [ -d /etc/init.d ]; then
  INIT=openrc
else
  INIT=none
fi

install_deps() (
  log "installing dependencies"
  if [ "$DISTRO_FAMILY" = alpine ]; then
    apk add --no-cache ca-certificates curl openssl jq >/dev/null
  elif [ "$DISTRO_FAMILY" = debian ]; then
    export DEBIAN_FRONTEND=noninteractive
    # Compressed, isolated indexes and separate download/install steps keep
    # apt and dpkg from exceeding the memory limit of small containers.
    DEPS_TMP=$(mktemp -d /tmp/sing-box-deps.XXXXXX)
    trap 'rm -rf "$DEPS_TMP"' 0
    chmod 0755 "$DEPS_TMP"
    install -d -m 0755 "$DEPS_TMP/lists" "$DEPS_TMP/archives"
    set -- -o "Dir::State::lists=$DEPS_TMP/lists" \
      -o "Dir::Cache::archives=$DEPS_TMP/archives" \
      -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache= \
      -o Acquire::Languages=none -o Acquire::GzipIndexes=true \
      -o Acquire::CompressionTypes::Order::=gz -o APT::Cache-Start=8388608
    apt-get "$@" update -qq >/dev/null
    apt-get "$@" install --download-only --no-install-recommends --no-upgrade \
      -y -qq ca-certificates curl openssl jq >/dev/null
    set -- "$DEPS_TMP"/archives/*.deb
    if [ -f "$1" ]; then
      # dpkg can install the set but leave a package unconfigured when a
      # dependency is configured later; one extra pass settles that. Real
      # failures surface in the command checks below.
      dpkg -i "$@" >/dev/null 2>&1 || dpkg --configure -a >/dev/null 2>&1 || :
    fi
  else
    die "no supported package manager found; install curl, openssl and jq manually"
  fi
  ok "ca-certificates, curl, openssl, jq"
)

ensure_deps() {
  missing=0
  for c in curl openssl jq; do
    command -v "$c" >/dev/null 2>&1 || missing=1
  done
  [ -d /etc/ssl/certs ] || missing=1
  [ "$missing" -eq 1 ] && install_deps
  command -v curl >/dev/null 2>&1 || die "curl is required"
  command -v openssl >/dev/null 2>&1 || die "openssl is required"
  command -v jq >/dev/null 2>&1 || die "jq is required"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)        echo amd64 ;;
    aarch64|arm64)       echo arm64 ;;
    armv7l|armv7)        echo armv7 ;;
    armv6l|armv6)        echo armv6 ;;
    armv5l|armv5)        echo armv5 ;;
    i386|i486|i586|i686) echo 386 ;;
    riscv64)             echo riscv64 ;;
    loongarch64|loong64) echo loong64 ;;
    s390x)               echo s390x ;;
    ppc64le)             echo ppc64le ;;
    mips64el)            echo mips64le ;;
    mipsel)              echo mipsle ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

fetch_binary() {
  ARCH=$(detect_arch)
  BASE="https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}"
  install -d -m 0755 "$BASE_DIR"
  TMP=$(mktemp -d "$BASE_DIR/dl.XXXXXX")

  if [ "$DISTRO_FAMILY" = alpine ]; then
    CANDIDATES="$ARCH-musl $ARCH"
  else
    CANDIDATES="$ARCH $ARCH-glibc $ARCH-musl"
  fi

  for variant in $CANDIDATES; do
    URL="$BASE/sing-box-${SING_BOX_VERSION}-linux-${variant}.tar.gz"
    log "downloading sing-box $SING_BOX_VERSION ($variant)"
    if ! curl -fsSL --retry 3 --connect-timeout 15 -o "$TMP/sb.tar.gz" "$URL" 2>/dev/null; then
      warn "no release asset for $variant"
      continue
    fi
    if ! tar -xzf "$TMP/sb.tar.gz" -C "$TMP" 2>/dev/null; then
      warn "could not extract $variant archive"
      continue
    fi
    CANDIDATE=$(find "$TMP" -type f -name sing-box | head -n 1)
    [ -n "$CANDIDATE" ] || { warn "no binary in $variant archive"; continue; }
    chmod +x "$CANDIDATE"
    if RUNERR=$("$CANDIDATE" version 2>&1 >/dev/null); then
      install -m 0755 "$CANDIDATE" "$BIN_PATH"
      rm -rf "$TMP"
      ok "installed $BIN_PATH ($variant)"
      return 0
    fi
    warn "$variant binary does not run on this system: $RUNERR"
  done

  rm -rf "$TMP"
  die "could not obtain a working sing-box binary for $ARCH"
}

resolve_version() {
  log "resolving latest sing-box release"
  LATEST_URL=$(curl -fsSLI -o /dev/null -w '%{url_effective}' --retry 3 --connect-timeout 15 \
    https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null) || LATEST_URL=""
  SING_BOX_VERSION=${LATEST_URL##*/v}
  case "$SING_BOX_VERSION" in
    ''|*[!0-9.]*) SING_BOX_VERSION=""; return 1 ;;
  esac
  ok "latest sing-box is $SING_BOX_VERSION"
}

ensure_binary() {
  if ! resolve_version; then
    [ -x "$BIN_PATH" ] || die "could not resolve the latest sing-box release"
    warn "could not resolve the latest sing-box release; keeping the installed binary"
    return 0
  fi
  if [ -x "$BIN_PATH" ]; then
    CURRENT=$("$BIN_PATH" version 2>/dev/null | awk '/^sing-box version/{print $3}') || CURRENT=""
    if [ "$CURRENT" = "$SING_BOX_VERSION" ]; then
      ok "sing-box $CURRENT already installed"
      return 0
    fi
    log "replacing sing-box ${CURRENT:-unknown} with $SING_BOX_VERSION"
  fi
  fetch_binary
}

ensure_dirs() {
  install -d -m 0755 "$CONF_DIR" "$LOG_DIR"
  chmod 0755 "$BASE_DIR"
}

# Clients keep working after a re-run because the saved credentials are written back.
# AnyTLS was added later, so an older config reuses everything it still has and
# only the missing AnyTLS password is generated by generate_credentials.
reuse_credentials() {
  [ -s "$CONF_FILE" ] && [ -s "$REALITY_PUBLIC_FILE" ] || return 1
  saved_settings=$(jq -er '
    (.inbounds[] | select(.type == "vless")) as $vless |
    (.inbounds[] | select(.type == "hysteria2")) as $hy2 |
    [$vless.users[0].uuid, $vless.tls.reality.private_key,
     $vless.tls.reality.short_id[0], $hy2.users[0].password] |
    if all(.[]; type == "string" and length > 0) then @tsv
    else error("missing saved credentials") end
  ' "$CONF_FILE" 2>/dev/null) || return 1
  IFS="$(printf '\t')" read -r VLESS_UUID REALITY_PRIVATE REALITY_SHORT_ID HY2_PASSWORD << SAVED
$saved_settings
SAVED
  ANYTLS_PASSWORD=$(jq -r '(.inbounds[]? | select(.type == "anytls") | .users[0].password) // empty' \
    "$CONF_FILE" 2>/dev/null) || ANYTLS_PASSWORD=""
  REALITY_PUBLIC=$(cat "$REALITY_PUBLIC_FILE")
}

generate_credentials() {
  if reuse_credentials; then
    ok "keeping existing credentials"
  else
    [ ! -s "$CONF_FILE" ] || warn "could not read the existing credentials; clients must be updated"
    log "generating fresh credentials"
    VLESS_UUID=$("$BIN_PATH" generate uuid) || die "could not generate VLESS UUID"
    reality_keypair=$("$BIN_PATH" generate reality-keypair) || die "could not generate REALITY key pair"
    REALITY_PRIVATE=$(printf '%s\n' "$reality_keypair" | awk '/^PrivateKey:/{print $2}')
    REALITY_PUBLIC=$(printf '%s\n' "$reality_keypair" | awk '/^PublicKey:/{print $2}')
    [ -n "$VLESS_UUID" ] && [ -n "$REALITY_PRIVATE" ] && [ -n "$REALITY_PUBLIC" ] || die "invalid generated credentials"
    REALITY_SHORT_ID=$(openssl rand -hex 8) || die "could not generate REALITY short ID"
    HY2_PASSWORD=$(openssl rand -hex 16) || die "could not generate Hysteria2 password"
  fi
  [ -n "$ANYTLS_PASSWORD" ] || ANYTLS_PASSWORD=$(openssl rand -hex 16) \
    || die "could not generate AnyTLS password"
}

write_config() (
  umask 077
  # Set permissions before writing, including when replacing an existing file.
  touch "$CONF_FILE" "$REALITY_PUBLIC_FILE" "$TLS_CERT_FILE" "$TLS_KEY_FILE"
  chmod 600 "$CONF_FILE" "$REALITY_PUBLIC_FILE" "$TLS_CERT_FILE" "$TLS_KEY_FILE"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$TLS_KEY_FILE" -out "$TLS_CERT_FILE" -days 3650 \
    -subj "/CN=$SNI" -addext "subjectAltName=DNS:$SNI" >/dev/null 2>&1 \
    || die "could not generate the TLS certificate"
  # Generated UUIDs, hex keys and base64url keys are safe in JSON strings.
  # Feed credentials through stdin so they do not appear in process arguments.
  jq . > "$CONF_FILE" << CONFIG
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "type": "local",
        "tag": "dns-local"
      }
    ],
    "rules": [
      {
        "query_type": [
          "AAAA"
        ],
        "action": "predefined"
      }
    ],
    "final": "dns-local",
    "strategy": "prefer_ipv4"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "0.0.0.0",
      "listen_port": 57351,
      "users": [
        {
          "name": "default",
          "uuid": "$VLESS_UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$SNI",
            "server_port": 443
          },
          "private_key": "$REALITY_PRIVATE",
          "short_id": [
            "$REALITY_SHORT_ID"
          ]
        }
      },
      "multiplex": {
        "enabled": true
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "0.0.0.0",
      "listen_port": 57353,
      "users": [
        {
          "name": "default",
          "password": "$HY2_PASSWORD"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "alpn": [
          "h3"
        ],
        "certificate_path": "$TLS_CERT_FILE",
        "key_path": "$TLS_KEY_FILE"
      }
    },
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "0.0.0.0",
      "listen_port": 57355,
      "users": [
        {
          "name": "default",
          "password": "$ANYTLS_PASSWORD"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "certificate_path": "$TLS_CERT_FILE",
        "key_path": "$TLS_KEY_FILE"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "direct",
    "default_domain_resolver": {
      "server": "dns-local",
      "strategy": "prefer_ipv4"
    }
  }
}
CONFIG
  printf '%s\n' "$REALITY_PUBLIC" > "$REALITY_PUBLIC_FILE"
)

load_credentials() {
  command -v jq >/dev/null 2>&1 || die "jq is required to read the saved configuration"
  client_settings=$(jq -er '
    (.inbounds[] | select(.type == "vless")) as $vless |
    (.inbounds[] | select(.type == "hysteria2")) as $hy2 |
    (.inbounds[] | select(.type == "anytls")) as $anytls |
    [$vless.users[0].uuid, $vless.tls.server_name,
     $vless.tls.reality.short_id[0], $hy2.users[0].password, $anytls.users[0].password] |
    if all(.[]; type == "string" and length > 0) then @tsv
    else error("missing client settings") end
  ' "$CONF_FILE") || die "could not read credentials from $CONF_FILE"
  [ -n "$client_settings" ] || die "no client credentials found in $CONF_FILE"
  IFS="$(printf '\t')" read -r VLESS_UUID SNI REALITY_SHORT_ID HY2_PASSWORD ANYTLS_PASSWORD << SETTINGS
$client_settings
SETTINGS
  [ -s "$REALITY_PUBLIC_FILE" ] || die "missing $REALITY_PUBLIC_FILE; re-run sb-anytls-ipv4.sh to generate credentials"
  REALITY_PUBLIC=$(cat "$REALITY_PUBLIC_FILE")
}

check_reality_dest() {
  log "checking REALITY destination $SNI:$REALITY_DEST_PORT"
  if command -v timeout >/dev/null 2>&1; then
    REALITY_CHECK=$(timeout 10 openssl s_client -connect "$SNI:$REALITY_DEST_PORT" \
        -servername "$SNI" -alpn h2 </dev/null 2>/dev/null || true)
  else
    REALITY_CHECK=$(openssl s_client -connect "$SNI:$REALITY_DEST_PORT" \
        -servername "$SNI" -alpn h2 </dev/null 2>/dev/null || true)
  fi
  case "$REALITY_CHECK" in
    *TLSv1.3*) ok "destination speaks TLS 1.3" ;;
    *) warn "could not confirm TLS 1.3 from $SNI -- REALITY clients may fail" ;;
  esac
}

# Runs before every start because a container restart resets these settings. Writes
# fail harmlessly where /proc/sys is read-only. Limiting unsent data drops the queue
# that builds when a fast download outruns the client, leaving data in flight alone.
# 1 MiB keeps the socket sending while a CPU quota has sing-box paused.
# The values come from cat because the kernel returns EOF to byte-wise shell reads.
TUNE_COMMAND='for f in /proc/sys/net/ipv4/tcp_rmem /proc/sys/net/ipv4/tcp_wmem; do set -- $(cat "$f" 2>/dev/null); [ "$#" -eq 3 ] && [ "$3" -gt '"$TCP_BUFFER_MAX"' ] && { echo "$1 $2 '"$TCP_BUFFER_MAX"'" > "$f"; } 2>/dev/null; done; { echo 1048576 > /proc/sys/net/ipv4/tcp_notsent_lowat; } 2>/dev/null; :'

rotate_logs() {
  [ -f "$LOG_FILE" ] || return 0
  size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
  [ "$size" -gt "$LOG_MAX_BYTES" ] || return 0
  if tail -c "$LOG_KEEP_BYTES" "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null; then
    cat "$LOG_FILE.tmp" > "$LOG_FILE"
  fi
  rm -f "$LOG_FILE.tmp"
}

start_rotator() {
  if [ -f "$ROTATOR_PID_FILE" ] && kill -0 "$(cat "$ROTATOR_PID_FILE")" 2>/dev/null; then
    return 0
  fi
  nohup sh -c '
    while :; do
      sleep 600
      [ -f "$1" ] || continue
      size=$(wc -c < "$1" 2>/dev/null || echo 0)
      [ "$size" -gt "$2" ] || continue
      if tail -c "$3" "$1" > "$1.tmp" 2>/dev/null; then
        cat "$1.tmp" > "$1"
      fi
      rm -f "$1.tmp"
    done
  ' log-rotator "$LOG_FILE" "$LOG_MAX_BYTES" "$LOG_KEEP_BYTES" >/dev/null 2>&1 &
  echo $! > "$ROTATOR_PID_FILE"
  rotate_logs
}

stop_rotator() {
  if [ -f "$ROTATOR_PID_FILE" ]; then
    kill "$(cat "$ROTATOR_PID_FILE")" 2>/dev/null || true
    rm -f "$ROTATOR_PID_FILE"
  fi
}

stop_existing() {
  case "$INIT" in
    systemd) systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true ;;
    openrc)  rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true ;;
  esac
  stop_pid_file
  stop_rotator
}

# Kills the pid recorded in PID_FILE and waits for it to go away; no init mode
# records the supervisor here, so a stuck child must not leave a stale pid file.
stop_pid_file() {
  [ -f "$PID_FILE" ] || return 0
  stop_pid=$(cat "$PID_FILE" 2>/dev/null) || stop_pid=""
  rm -f "$PID_FILE"
  [ -n "$stop_pid" ] || return 0
  kill "$stop_pid" 2>/dev/null || true
  i=0
  while kill -0 "$stop_pid" 2>/dev/null && [ "$i" -lt 10 ]; do
    sleep 1
    i=$((i + 1))
  done
  kill -9 "$stop_pid" 2>/dev/null || true
  return 0
}

# A service file is ours when it carries the marker, or when it runs this exact
# binary and config: that is the same layout from an earlier script (upstream
# sb.sh), so upgrading it is safe.
unit_is_ours() {
  [ -f "$1" ] || return 1
  grep -qF "$UNIT_MARKER" "$1" 2>/dev/null && return 0
  grep -qF "$BIN_PATH" "$1" 2>/dev/null && grep -qF "$CONF_FILE" "$1" 2>/dev/null
}

# Refuses to take over a service file this script did not write. Generic
# "sing-box" is a common service name, so an existing unit means another
# install owns it and stopping it would break that one.
check_service_collision() {
  case "$INIT" in
    systemd) collision_target=$SYSTEMD_UNIT ;;
    openrc)  collision_target=$INITD_FILE ;;
    *) return 0 ;;
  esac
  [ -f "$collision_target" ] || return 0
  unit_is_ours "$collision_target" && return 0
  die "$collision_target exists and belongs to another sing-box install; move it aside first"
}

install_service() {
  case "$INIT" in
    systemd)
      cat > "$SYSTEMD_UNIT" << UNIT
$UNIT_MARKER
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStartPre=-/bin/sh -c '$(printf '%s' "$TUNE_COMMAND" | sed 's/\$/$$/g')'
ExecStart=$BIN_PATH run -c $CONF_FILE
Environment=GOMEMLIMIT=$GO_MEMORY_LIMIT
Environment=GODEBUG=disablethp=1
Restart=always
RestartSec=3s
LimitNOFILE=infinity
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
UNIT
      systemctl daemon-reload
      systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
      ok "systemd unit installed"
      ;;
    openrc)
      sed -e "s|@MARK@|$UNIT_MARKER|g" \
          -e "s|@BIN@|$BIN_PATH|g" \
          -e "s|@CONF@|$CONF_FILE|g" \
          -e "s|@LOG@|$LOG_FILE|g" \
          -e "s|@RPID@|$ROTATOR_PID_FILE|g" \
          -e "s|@RMAX@|$LOG_MAX_BYTES|g" \
          -e "s|@RKEEP@|$LOG_KEEP_BYTES|g" \
          -e "s|@TUNE@|$(printf '%s' "$TUNE_COMMAND" | sed 's/[&\\|]/\\&/g')|g" \
          -e "s|@GOMEMLIMIT@|$GO_MEMORY_LIMIT|g" > "$INITD_FILE" << 'INITD'
#!/sbin/openrc-run
@MARK@

name="sing-box"
description="sing-box proxy server"

supervisor="supervise-daemon"
command="@BIN@"
command_args="run -c @CONF@"
output_log="@LOG@"
error_log="@LOG@"
respawn_delay=3
respawn_max=0

export GOMEMLIMIT="@GOMEMLIMIT@"
export GODEBUG="disablethp=1"

rotator_pid="@RPID@"

start_pre() {
  @TUNE@
  if [ -f "$rotator_pid" ] && kill -0 "$(cat "$rotator_pid")" 2>/dev/null; then
    return 0
  fi
  nohup sh -c '
    while :; do
      sleep 600
      [ -f "$1" ] || continue
      size=$(wc -c < "$1" 2>/dev/null || echo 0)
      [ "$size" -gt "$2" ] || continue
      if tail -c "$3" "$1" > "$1.tmp" 2>/dev/null; then
        cat "$1.tmp" > "$1"
      fi
      rm -f "$1.tmp"
    done
  ' log-rotator "@LOG@" @RMAX@ @RKEEP@ >/dev/null 2>&1 &
  echo $! > "$rotator_pid"
  return 0
}

stop_post() {
  if [ -f "$rotator_pid" ]; then
    kill "$(cat "$rotator_pid")" 2>/dev/null
    rm -f "$rotator_pid"
  fi
  return 0
}

depend() {
  need net
  after firewall
}
INITD
      chmod 0755 "$INITD_FILE"
      rc-update add "$SERVICE_NAME" default >/dev/null 2>&1
      ok "openrc service installed"
      ;;
    none)
      warn "no init system found; sing-box will run as a background process"
      ;;
  esac
}

start_service() {
  case "$INIT" in
    systemd) systemctl start "$SERVICE_NAME" ;;
    openrc)  rc-service "$SERVICE_NAME" start >/dev/null 2>&1 ;;
    none)
      sh -c "$TUNE_COMMAND" || :
      GOMEMLIMIT="$GO_MEMORY_LIMIT" GODEBUG=disablethp=1 nohup sh -c '
        trap "kill \$child 2>/dev/null; wait \$child; exit 0" TERM
        while :; do
          "$1" run -c "$2" >>"$3" 2>&1 &
          child=$!
          wait "$child"
          sleep 3
        done
      ' sing-box-supervisor "$BIN_PATH" "$CONF_FILE" "$LOG_FILE" >/dev/null 2>&1 &
      echo $! > "$PID_FILE"
      start_rotator
      ;;
  esac
}

verify_listening() {
  sleep 2
  # A check needs one of these tools; without them the old code silently reported
  # success, so say so instead of claiming the ports are open.
  if command -v ss >/dev/null 2>&1; then
    listener_tool=ss
  elif command -v netstat >/dev/null 2>&1; then
    listener_tool=netstat
  elif command -v lsof >/dev/null 2>&1; then
    listener_tool=lsof
  else
    warn "no ss, netstat or lsof here; could not verify the listening ports"
    warn "expected $VLESS_PORT/tcp, $HY2_PORT/udp and $ANYTLS_PORT/tcp -- check the logs"
    return 0
  fi
  failed=0
  for p in "$VLESS_PORT/tcp" "$HY2_PORT/udp" "$ANYTLS_PORT/tcp"; do
    port=${p%/*}
    proto=${p#*/}
    case "$listener_tool" in
      ss)
        if [ "$proto" = tcp ]; then ss_flags=-lnt; else ss_flags=-lnu; fi
        ss "$ss_flags" 2>/dev/null | grep -qE "[:.]${port}[[:space:]]" || failed=1
        ;;
      netstat)
        netstat -an 2>/dev/null | grep -qE "^${proto}.*[:.]${port}[[:space:]]" || failed=1
        ;;
      lsof)
        if [ "$proto" = tcp ]; then
          lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 || failed=1
        else
          lsof -nP -iUDP:"$port" >/dev/null 2>&1 || failed=1
        fi
        ;;
    esac
  done
  if [ "$failed" -eq 1 ]; then
    warn "one or more ports are not listening -- check the logs:"
    if [ "$INIT" = systemd ]; then
      printf '  journalctl -u %s -n 50 --no-pager\n' "$SERVICE_NAME"
    else
      printf '  tail -n 50 %s\n' "$LOG_FILE"
    fi
    exit 1
  fi
  ok "listening on $VLESS_PORT/tcp, $HY2_PORT/udp and $ANYTLS_PORT/tcp"
}

public_ip() {
  for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip=$(curl -4 -fsS --connect-timeout 3 --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]') || ip=""
    case "$ip" in
      *[!0-9a-fA-F:.]*|"") continue ;;
      *) printf '%s' "$ip"; return 0 ;;
    esac
  done
  return 1
}

print_section() {
  section_head="-- $1  $2 "
  section_fill=$((56 - ${#section_head}))
  section_rule=$(printf '%s' '--------------------------------------------------------' | cut -c1-"$section_fill")
  printf '\n%s%s%s%s\n' "$C_BOLD" "$section_head" "$section_rule" "$C_RESET"
}

detect_server() {
  [ -z "$SERVER" ] || return 0
  SERVER_IPV4=$(public_ip) || SERVER_IPV4=""
  SERVER="${SERVER_IPV4:-<your-server-ip>}"
}

# --show used to claim the service was running without looking at it. Always
# return 0 so the caller can use the value under "set -e".
service_status() {
  if [ "$INIT" = systemd ]; then
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
      printf running
    else
      printf stopped
    fi
  elif [ "$INIT" = openrc ]; then
    if rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
      printf running
    else
      printf stopped
    fi
  elif [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    printf running
  else
    printf stopped
  fi
  return 0
}

show_links() {
  load_credentials
  detect_server
  if [ "$(service_status)" = running ]; then
    service_head="sing-box is running"
  else
    service_head="sing-box is NOT running -- start it, then run --show again"
  fi
  printf '\n%s========================================================%s\n' "$C_BOLD" "$C_RESET"
  printf '%s  %s%s\n' "$C_BOLD" "$service_head" "$C_RESET"
  printf '%s========================================================%s\n' "$C_BOLD" "$C_RESET"
  printf '  ipv4        %s\n' "$SERVER"

  print_section "VLESS + REALITY" "$VLESS_PORT/tcp"
  printf '  vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#reality\n' \
    "$VLESS_UUID" "$SERVER" "$VLESS_PORT" "$SNI" "$REALITY_PUBLIC" "$REALITY_SHORT_ID"
  printf '  uuid        %s\n' "$VLESS_UUID"
  printf '  public key  %s\n' "$REALITY_PUBLIC"
  printf '  short id    %s\n' "$REALITY_SHORT_ID"
  printf '  sni         %s\n' "$SNI"

  print_section "Hysteria2" "$HY2_PORT/udp"
  printf '  hysteria2://%s@%s:%s?sni=%s&alpn=h3&insecure=1#hysteria2\n' \
    "$HY2_PASSWORD" "$SERVER" "$HY2_PORT" "$SNI"
  printf '  password    %s\n' "$HY2_PASSWORD"
  printf '  sni         %s\n' "$SNI"

  print_section "AnyTLS" "$ANYTLS_PORT/tcp"
  printf '  anytls://%s@%s:%s?sni=%s&insecure=1#anytls\n' \
    "$ANYTLS_PASSWORD" "$SERVER" "$ANYTLS_PORT" "$SNI"
  printf '  password    %s\n' "$ANYTLS_PASSWORD"
  printf '  sni         %s\n' "$SNI"
  printf '  note        self-signed certificate; the client skips verification\n'

  printf '\n%s========================================================%s\n\n' "$C_BOLD" "$C_RESET"
}

# Real IPs for China and LAN answers from 223.5.5.5, fake IPs for everything else,
# so proxied traffic keeps its domain and is resolved on the server. A route
# "resolve" action cannot do this: it hands the proxy the possibly poisoned IP.
# This build is IPv4-only, so AAAA and HTTPS/SVCB queries get an empty answer and
# no IPv6 address is ever handed to the host. IPv6 traffic that still reaches
# sing-box (a literal address, a cached record) is rejected instead of being
# dialled around the tunnel; only the TUN has no IPv6 route, so a host with
# working IPv6 should also disable IPv6 itself for a complete block.
# $1 adds platform differences.
singbox_client_config() {
  jq "$1" << CONFIG
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "type": "udp",
        "tag": "dns-ali",
        "server": "223.5.5.5"
      },
      {
        "type": "local",
        "tag": "dns-local"
      },
      {
        "type": "fakeip",
        "tag": "dns-fake",
        "inet4_range": "198.18.0.0/15"
      }
    ],
    "rules": [
      {
        "domain_suffix": ["lan", "local", "home.arpa"],
        "server": "dns-local"
      },
      {
        "query_type": ["HTTPS", "SVCB"],
        "action": "predefined"
      },
      {
        "query_type": ["AAAA"],
        "action": "predefined"
      },
      {
        "query_type": ["A"],
        "action": "evaluate",
        "server": "dns-ali"
      },
      {
        "match_response": true,
        "rule_set": "geoip-cn",
        "action": "respond"
      },
      {
        "match_response": true,
        "ip_is_private": true,
        "action": "respond"
      },
      {
        "query_type": ["A"],
        "server": "dns-fake"
      }
    ],
    "final": "dns-ali"
  },
  "http_clients": [
    {
      "tag": "via-proxy",
      "detour": "PROXY"
    }
  ],
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "address": ["172.19.0.1/30"],
      "auto_route": true
    }
  ],
  "outbounds": [
    {
      "type": "selector",
      "tag": "PROXY",
      "outbounds": ["reality", "hysteria2", "anytls"],
      "default": "reality"
    },
    {
      "type": "vless",
      "tag": "reality",
      "server": "$SERVER",
      "server_port": $VLESS_PORT,
      "uuid": "$VLESS_UUID",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "$REALITY_PUBLIC",
          "short_id": "$REALITY_SHORT_ID"
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hysteria2",
      "server": "$SERVER",
      "server_port": $HY2_PORT,
      "password": "$HY2_PASSWORD",
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "insecure": true,
        "alpn": ["h3"]
      }
    },
    {
      "type": "anytls",
      "tag": "anytls",
      "server": "$SERVER",
      "server_port": $ANYTLS_PORT,
      "password": "$ANYTLS_PASSWORD",
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "insecure": true
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "ip_version": 6,
        "action": "reject"
      },
      {
        "action": "sniff"
      },
      {
        "protocol": "dns",
        "action": "hijack-dns"
      },
      {
        "ip_is_private": true,
        "outbound": "direct"
      },
      {
        "rule_set": "geoip-cn",
        "outbound": "direct"
      }
    ],
    "rule_set": [
      {
        "type": "remote",
        "tag": "geoip-cn",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs"
      }
    ],
    "final": "PROXY",
    "auto_detect_interface": true,
    "default_domain_resolver": "dns-ali",
    "default_http_client": "via-proxy"
  },
  "experimental": {
    "cache_file": {
      "enabled": true,
      "store_fakeip": true
    }
  }
}
CONFIG
}

# Sends LAN traffic around the TUN so devices on the LAN can reach this one.
# 172.19.0.0/16 stays routed because it holds the TUN's own address.
SINGBOX_LAN_ROUTES='.inbounds[0].route_exclude_address = [
  "10.0.0.0/8", "169.254.0.0/16", "172.16.0.0/15", "172.18.0.0/16",
  "172.20.0.0/14", "172.24.0.0/13", "192.168.0.0/16"
]'

singbox_client_pc() {
  singbox_client_config "$SINGBOX_LAN_ROUTES | .inbounds[0].strict_route = true"
}

singbox_client_android() {
  singbox_client_config "$SINGBOX_LAN_ROUTES"
}

singbox_client_ios() {
  singbox_client_config .
}

# mihomo needs 1.19.0 or newer for the anytls proxy type.
clash_client_common() {
  cat << CONFIG
# Written by sb-anytls-ipv4.sh. Contains credentials, so keep this file private.
mode: rule
log-level: warning
ipv6: false
profile:
  store-selected: true
  store-fake-ip: true
geo-auto-update: true
geo-update-interval: 168
geox-url:
  mmdb: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country-lite.mmdb"
dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - "+.lan"
    - "+.local"
    - "+.home.arpa"
    - "+.msftconnecttest.com"
    - "+.msftncsi.com"
  default-nameserver:
    - 223.5.5.5
  nameserver:
    - 223.5.5.5
  nameserver-policy:
    "+.lan": system
    "+.local": system
    "+.home.arpa": system
proxies:
  - name: reality
    type: vless
    server: "$SERVER"
    port: $VLESS_PORT
    uuid: "$VLESS_UUID"
    flow: xtls-rprx-vision
    packet-encoding: xudp
    udp: true
    tls: true
    servername: "$SNI"
    client-fingerprint: chrome
    reality-opts:
      public-key: "$REALITY_PUBLIC"
      short-id: "$REALITY_SHORT_ID"
  - name: hysteria2
    type: hysteria2
    server: "$SERVER"
    port: $HY2_PORT
    password: "$HY2_PASSWORD"
    sni: "$SNI"
    skip-cert-verify: true
    alpn:
      - h3
  - name: anytls
    type: anytls
    server: "$SERVER"
    port: $ANYTLS_PORT
    password: "$ANYTLS_PASSWORD"
    client-fingerprint: chrome
    udp: true
    sni: "$SNI"
    skip-cert-verify: true
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - reality
      - hysteria2
      - anytls
rules:
  - IP-CIDR,10.0.0.0/8,DIRECT
  - IP-CIDR,127.0.0.0/8,DIRECT
  - IP-CIDR,169.254.0.0/16,DIRECT
  - IP-CIDR,172.16.0.0/12,DIRECT
  - IP-CIDR,192.168.0.0/16,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
CONFIG
}

clash_client_pc() {
  clash_client_common
  cat << 'CONFIG'
mixed-port: 7890
tun:
  enable: true
  auto-route: true
  auto-detect-interface: true
  strict-route: true
  dns-hijack:
    - any:53
    - tcp://any:53
  route-exclude-address:
    - 10.0.0.0/8
    - 169.254.0.0/16
    - 172.16.0.0/12
    - 192.168.0.0/16
CONFIG
}

# No local proxy port: other apps on a phone could find and use it.
clash_client_mobile() {
  clash_client_common
  cat << 'CONFIG'
find-process-mode: "off"
tun:
  enable: true
  auto-route: true
  auto-detect-interface: true
  dns-hijack:
    - any:53
    - tcp://any:53
CONFIG
}

# Egern is only available on Apple devices.
egern_client() {
  cat << CONFIG
# Written by sb-anytls-ipv4.sh. Contains credentials, so keep this file private.
ipv6: false
hijack_dns:
  - "*"
real_ip_domains:
  - "*.lan"
  - "*.local"
  - "*.home.arpa"
dns:
  bootstrap:
    - 223.5.5.5
  forward:
    - domain_suffix:
        match: lan
        value: system
    - domain_suffix:
        match: local
        value: system
    - domain_suffix:
        match: home.arpa
        value: system
proxies:
  - vless:
      name: reality
      server: "$SERVER"
      port: $VLESS_PORT
      user_id: "$VLESS_UUID"
      flow: xtls-rprx-vision
      udp_relay: true
      transport:
        tls:
          sni: "$SNI"
          reality:
            public_key: "$REALITY_PUBLIC"
            short_id: "$REALITY_SHORT_ID"
  - hysteria2:
      name: hysteria2
      server: "$SERVER"
      port: $HY2_PORT
      auth: "$HY2_PASSWORD"
      sni: "$SNI"
      skip_tls_verify: true
  - anytls:
      name: anytls
      server: "$SERVER"
      port: $ANYTLS_PORT
      password: "$ANYTLS_PASSWORD"
      sni: "$SNI"
      udp_relay: true
      skip_tls_verify: true
policy_groups:
  - select:
      name: PROXY
      policies:
        - reality
        - hysteria2
        - anytls
rules:
  - ip_cidr:
      match: 10.0.0.0/8
      policy: DIRECT
  - ip_cidr:
      match: 127.0.0.0/8
      policy: DIRECT
  - ip_cidr:
      match: 169.254.0.0/16
      policy: DIRECT
  - ip_cidr:
      match: 172.16.0.0/12
      policy: DIRECT
  - ip_cidr:
      match: 192.168.0.0/16
      policy: DIRECT
  - geoip:
      match: CN
      policy: DIRECT
  - default:
      policy: PROXY
CONFIG
}

write_client_file() {
  client_file="$BASE_DIR/$1"
  touch "$client_file" && chmod 600 "$client_file" || die "could not create $client_file"
  "$2" > "$client_file" || die "could not write $client_file"
}

write_client_configs() {
  load_credentials
  detect_server
  if [ "$SERVER" = "<your-server-ip>" ]; then
    warn "could not detect this server's public IP; client configs were not written"
    return 1
  fi
  (
    umask 077
    write_client_file clash-pc.yaml clash_client_pc
    write_client_file clash-mobile.yaml clash_client_mobile
    write_client_file singbox-pc.json singbox_client_pc
    write_client_file singbox-android.json singbox_client_android
    write_client_file singbox-ios.json singbox_client_ios
    write_client_file egern.yaml egern_client
    rm -rf "$OLD_CLIENT_DIR"
  ) || return 1

  # Parse the three sing-box client files with the same binary. A failure is only
  # a warning: a client-only option can be rejected here for reasons that do not
  # affect the target device, and that must not fail an otherwise good install.
  for client_file in singbox-pc.json singbox-android.json singbox-ios.json; do
    if "$BIN_PATH" check -c "$BASE_DIR/$client_file" >/dev/null 2>&1; then
      ok "validated $client_file"
    else
      warn "$client_file did not pass the sing-box config check"
    fi
  done

  printf '%s========================================================%s\n' "$C_BOLD" "$C_RESET"
  printf '%s  Config files%s\n' "$C_BOLD" "$C_RESET"
  printf '%s========================================================%s\n' "$C_BOLD" "$C_RESET"
  printf '  %s\n\n' "$BASE_DIR"
  printf '  Clash (PC/Mac)       clash-pc.yaml\n'
  printf '  Clash (Android/iOS)  clash-mobile.yaml\n'
  printf '  sing-box (PC/Mac)    singbox-pc.json\n'
  printf '  sing-box (Android)   singbox-android.json\n'
  printf '  sing-box (iOS)       singbox-ios.json\n'
  printf '  Egern (Apple)        egern.yaml\n\n'
  printf '  The sing-box client files need sing-box 1.14.0 or newer\n'
  printf '  (they use http_clients and the DNS evaluate action).\n'
  printf '  The Clash files need mihomo 1.19.0 or newer for the anytls proxy.\n\n'
}

uninstall() {
  log "stopping and removing sing-box"
  case "$INIT" in
    systemd)
      if [ -f "$SYSTEMD_UNIT" ] && ! unit_is_ours "$SYSTEMD_UNIT"; then
        warn "$SYSTEMD_UNIT belongs to another install; leaving it running and in place"
      else
        systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
        systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
        rm -f "$SYSTEMD_UNIT"
        systemctl daemon-reload >/dev/null 2>&1 || true
      fi
      ;;
    openrc)
      if [ -f "$INITD_FILE" ] && ! unit_is_ours "$INITD_FILE"; then
        warn "$INITD_FILE belongs to another install; leaving it running and in place"
      else
        rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
        rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true
        rm -f "$INITD_FILE"
      fi
      ;;
  esac
  stop_pid_file
  stop_rotator
  rm -rf "$CONF_DIR" "$OLD_CLIENT_DIR" "$LOG_DIR" "$BIN_PATH" "$PID_FILE" "$ROTATOR_PID_FILE" "$BASE_DIR"/dl.*
  for client_file in $CLIENT_FILES; do
    rm -f "$BASE_DIR/$client_file"
  done
  rmdir "$BASE_DIR" 2>/dev/null || true
  ok "removed sing-box, its configuration, and its service"
}

do_install() {
  log "distribution: $DISTRO ($DISTRO_FAMILY), init: $INIT"
  if [ "$DISTRO_FAMILY" = unknown ] && [ "$INIT" = none ]; then
    warn "unrecognised platform; continuing with manual dependency handling"
  fi

  # Before anything is stopped or replaced: make sure the service is ours.
  check_service_collision

  ensure_deps
  ensure_binary
  ensure_dirs
  generate_credentials

  log "writing configuration to $CONF_FILE"
  write_config

  if ! "$BIN_PATH" check -c "$CONF_FILE" >/dev/null 2>&1; then
    "$BIN_PATH" check -c "$CONF_FILE" || true
    die "generated configuration failed validation"
  fi
  ok "configuration validated"

  check_reality_dest
  rm -f "$CONF_DIR/tune.sh"

  stop_existing
  install_service
  log "starting sing-box"
  start_service
  verify_listening
  show_links
  write_client_configs || warn "client configs were not written; try: $0 --client-config"
}

case "$MODE" in
  install)   do_install ;;
  show)
    [ -f "$CONF_FILE" ] || die "no installation found at $CONF_FILE"
    show_links
    ;;
  client-config)
    [ -f "$CONF_FILE" ] || die "no installation found at $CONF_FILE"
    write_client_configs || exit 1
    ;;
  uninstall) uninstall ;;
esac
