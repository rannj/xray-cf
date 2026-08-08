#!/usr/bin/env bash
set -euo pipefail

# xray-cf-lite: VLESS + XHTTP over Cloudflare Tunnel

XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG_PATH="$XRAY_CONFIG_DIR/config.json"
XRAY_BINARY="/usr/local/bin/xray"
XRAY_OPENRC_SCRIPT="/etc/init.d/xray"

STATE_DIR="/etc/xray-cf-lite"
STATE_PATH="$STATE_DIR/state.json"
TUNNEL_TOKEN_PATH="$STATE_DIR/tunnel.token"
LAST_LINKS_PATH="$(pwd)/cf_lite_last_links.txt"

CLOUDFLARED_SERVICE="cloudflared-xray"
CLOUDFLARED_SYSTEMD_PATH="/etc/systemd/system/${CLOUDFLARED_SERVICE}.service"
CLOUDFLARED_OPENRC_PATH="/etc/init.d/${CLOUDFLARED_SERVICE}"
XRAY_INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
info() { printf '\033[36m·\033[0m %s\n' "$*"; }
need_cmd() { command -v "$1" &>/dev/null || die "缺少依赖: $1"; }

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) \
        || die "无效端口: $port（有效范围 1-65535）"
}

urlencode() {
    local s="$1" c
    local -i i
    for ((i=0; i<${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) printf '%s' "$c" ;;
            *) printf '%%%02X' "'$c" ;;
        esac
    done
}

write_file_atomic() {
    local target="$1" mode="$2" content="$3" dir tmp
    dir=$(dirname "$target")
    mkdir -p "$dir"
    tmp=$(mktemp "${dir}/.$(basename "$target").XXXXXX") || die "无法创建临时文件: $dir"
    printf '%s\n' "$content" > "$tmp"
    chmod "$mode" "$tmp"
    mv -f "$tmp" "$target"
}

gen_uuid() {
    cat /proc/sys/kernel/random/uuid 2>/dev/null \
        || uuidgen | tr '[:upper:]' '[:lower:]'
}

INIT_SYSTEM=""
detect_init() {
    if command -v systemctl &>/dev/null && systemctl --version &>/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service &>/dev/null; then
        INIT_SYSTEM="openrc"
    else
        die "不支持的 init 系统（需要 systemd 或 OpenRC）"
    fi
}

install_deps() {
    local missing=()
    command -v curl &>/dev/null || missing+=(curl)
    command -v jq &>/dev/null || missing+=(jq)
    command -v unzip &>/dev/null || missing+=(unzip)
    [[ ${#missing[@]} -eq 0 ]] && return

    info "安装依赖: ${missing[*]}"
    if command -v apk &>/dev/null; then
        apk add --no-cache "${missing[@]}"
    elif command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq "${missing[@]}"
    elif command -v yum &>/dev/null; then
        yum install -y "${missing[@]}"
    else
        die "无法安装依赖 ${missing[*]}，请手动安装"
    fi
}

CLOUDFLARED_BINARY=""
check_cloudflared() {
    CLOUDFLARED_BINARY=$(command -v cloudflared || true)
    [[ -n "$CLOUDFLARED_BINARY" ]] \
        || die "未找到 cloudflared；请先自行安装（脚本不会安装）"

    local version
    version=$($CLOUDFLARED_BINARY --version 2>/dev/null | grep -oE '[0-9]{4}\.[0-9]+\.[0-9]+' | head -1 || true)
    [[ -n "$version" ]] || die "无法识别 cloudflared 版本"
    [[ "$(printf '%s\n%s\n' "2025.4.0" "$version" | sort -V | head -1)" == "2025.4.0" ]] \
        || die "cloudflared $version 过旧，--token-file 需要 2025.4.0 或更高版本"
    info "cloudflared $version"
}

write_xray_openrc_script() {
    cat > "$XRAY_OPENRC_SCRIPT" <<'EOF'
#!/sbin/openrc-run
name="xray"
description="Xray proxy server"
command="/usr/local/bin/xray"
command_args="run -config /usr/local/etc/xray/config.json"
command_background=true
pidfile="/run/xray.pid"
output_log="/var/log/xray.log"
error_log="/var/log/xray.log"
supervisor=supervise-daemon
supervise_daemon_args="--respawn-delay 1 --respawn-max 0 --respawn-period 86400"
depend() { need net; after firewall; }
EOF
    chmod +x "$XRAY_OPENRC_SCRIPT"
}

ensure_systemd_xray_restart() {
    [[ "$INIT_SYSTEM" == "systemd" ]] || return
    local drop="/etc/systemd/system/xray.service.d"
    mkdir -p "$drop"
    cat > "$drop/restart.conf" <<'EOF'
[Service]
Restart=on-failure
RestartSec=1
EOF
    systemctl daemon-reload
}

xray_start() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        ensure_systemd_xray_restart
        systemctl enable xray &>/dev/null
        systemctl restart xray
        systemctl is-active xray &>/dev/null || die "xray 未正常启动"
    else
        [[ -f "$XRAY_OPENRC_SCRIPT" ]] || write_xray_openrc_script
        rc-update add xray default &>/dev/null
        rc-service xray restart
        rc-service xray status &>/dev/null 2>&1 || die "xray 未正常启动"
    fi
    ok "xray 服务已启动"
}

xray_stop() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl stop xray &>/dev/null || true
        systemctl disable xray &>/dev/null || true
    else
        rc-service xray stop &>/dev/null || true
        rc-update del xray default &>/dev/null || true
    fi
}

xray_is_active() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl is-active xray &>/dev/null
    else
        rc-service xray status &>/dev/null 2>&1
    fi
}

write_cloudflared_service() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        cat > "$CLOUDFLARED_SYSTEMD_PATH" <<EOF
[Unit]
Description=Cloudflare Tunnel for xray-cf-lite
After=network-online.target xray.service
Wants=network-online.target
Requires=xray.service

[Service]
Type=simple
ExecStart=$CLOUDFLARED_BINARY tunnel --no-autoupdate run --token-file $TUNNEL_TOKEN_PATH
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    else
        cat > "$CLOUDFLARED_OPENRC_PATH" <<EOF
#!/sbin/openrc-run
name="$CLOUDFLARED_SERVICE"
description="Cloudflare Tunnel for xray-cf-lite"
command="$CLOUDFLARED_BINARY"
command_args="tunnel --no-autoupdate run --token-file $TUNNEL_TOKEN_PATH"
command_background=true
pidfile="/run/$CLOUDFLARED_SERVICE.pid"
output_log="/var/log/$CLOUDFLARED_SERVICE.log"
error_log="/var/log/$CLOUDFLARED_SERVICE.log"
supervisor=supervise-daemon
supervise_daemon_args="--respawn-delay 2 --respawn-max 0 --respawn-period 86400"
depend() { need net; after xray; }
EOF
        chmod +x "$CLOUDFLARED_OPENRC_PATH"
    fi
}

cloudflared_start() {
    write_cloudflared_service
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl enable "$CLOUDFLARED_SERVICE" &>/dev/null
        systemctl restart "$CLOUDFLARED_SERVICE"
        sleep 2
        systemctl is-active "$CLOUDFLARED_SERVICE" &>/dev/null \
            || die "cloudflared-xray 启动失败，请查看 journalctl -u $CLOUDFLARED_SERVICE"
    else
        rc-update add "$CLOUDFLARED_SERVICE" default &>/dev/null
        rc-service "$CLOUDFLARED_SERVICE" restart
        sleep 2
        rc-service "$CLOUDFLARED_SERVICE" status &>/dev/null 2>&1 \
            || die "cloudflared-xray 启动失败，请查看 /var/log/$CLOUDFLARED_SERVICE.log"
    fi
    ok "Cloudflare Tunnel 服务已启动"
}

cloudflared_stop() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl stop "$CLOUDFLARED_SERVICE" &>/dev/null || true
        systemctl disable "$CLOUDFLARED_SERVICE" &>/dev/null || true
        rm -f "$CLOUDFLARED_SYSTEMD_PATH"
        systemctl daemon-reload
    else
        rc-service "$CLOUDFLARED_SERVICE" stop &>/dev/null || true
        rc-update del "$CLOUDFLARED_SERVICE" default &>/dev/null || true
        rm -f "$CLOUDFLARED_OPENRC_PATH"
    fi
}

cloudflared_is_active() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl is-active "$CLOUDFLARED_SERVICE" &>/dev/null
    else
        rc-service "$CLOUDFLARED_SERVICE" status &>/dev/null 2>&1
    fi
}

install_xray() {
    echo "正在安装 xray-core ..."
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        if curl -fsSL "$XRAY_INSTALL_URL" | bash -s -- install; then
            [[ -x "$XRAY_BINARY" ]] && { ok "xray-core 安装完成"; return; }
        fi
    fi

    local arch version tmp
    case "$(uname -m)" in
        x86_64|amd64) arch="64" ;;
        aarch64|arm64) arch="arm64-v8a" ;;
        armv7*) arch="arm32-v7a" ;;
        *) die "不支持的架构: $(uname -m)" ;;
    esac
    version=$(curl -fsSL --retry 2 --connect-timeout 10 \
        https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name')
    [[ -n "$version" && "$version" != "null" ]] || die "获取 xray 版本失败"

    tmp=$(mktemp -d /tmp/xray-install.XXXXXX)
    curl -fsSL --retry 2 --connect-timeout 10 -o "$tmp/xray.zip" \
        "https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-linux-${arch}.zip"
    unzip -o "$tmp/xray.zip" xray -d /usr/local/bin/
    chmod +x "$XRAY_BINARY"
    rm -rf "$tmp"
    ok "xray-core 安装完成: $($XRAY_BINARY version | head -1)"
}

gen_xray_config() {
    local port="$1" uid="$2" path="$3"
    jq -n --argjson port "$port" --arg uid "$uid" --arg path "$path" '{
        log:{loglevel:"warning"},
        inbounds:[{
            tag:"in-vless-xhttp",
            listen:"127.0.0.1",
            port:$port,
            protocol:"vless",
            settings:{users:[{id:$uid}],decryption:"none"},
            streamSettings:{method:"xhttp",security:"none",xhttpSettings:{path:$path}},
            sniffing:{enabled:true,destOverride:["http","tls","quic"]}
        }],
        outbounds:[
            {tag:"direct",protocol:"freedom"},
            {tag:"block",protocol:"blackhole"}
        ],
        routing:{domainStrategy:"AsIs",rules:[
            {type:"field",outboundTag:"block",protocol:["bittorrent"]}
        ]}
    }'
}

write_xray_config() {
    local content="$1" tmp validation_output
    mkdir -p "$XRAY_CONFIG_DIR"
    tmp=$(mktemp "$XRAY_CONFIG_DIR/.config.json.XXXXXX")
    printf '%s\n' "$content" > "$tmp"
    if ! validation_output=$("$XRAY_BINARY" run -test -config "$tmp" 2>&1); then
        printf '%s\n' "$validation_output" >&2
        rm -f "$tmp"
        die "生成的 Xray 配置未通过校验"
    fi
    chmod 644 "$tmp"
    mv -f "$tmp" "$XRAY_CONFIG_PATH"
    ok "xray 配置已写入 $XRAY_CONFIG_PATH"
}

build_link() {
    local uid="$1" domain="$2" path="$3" query name
    query="encryption=none&security=tls&sni=$(urlencode "$domain")&fp=chrome&type=xhttp&path=$(urlencode "$path")&mode=stream-up"
    name=$(urlencode "VLESS XHTTP Tunnel ${domain}")
    printf 'vless://%s@%s:443?%s#%s\n' "$uid" "$domain" "$query" "$name"
}

load_state() { [[ -f "$STATE_PATH" ]] && jq -e '.' "$STATE_PATH"; }
load_existing_state() {
    [[ -f "$STATE_PATH" ]] || die "未检测到部署"
    load_state 2>/dev/null || die "状态文件损坏: $STATE_PATH"
}
save_state() {
    local state_json="$1"
    echo "$state_json" | jq -e '.' &>/dev/null || die "拒绝写入无效状态 JSON"
    mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
    write_file_atomic "$STATE_PATH" 600 "$state_json"
}

prompt_uuid() {
    local value
    read -rp "UUID(留空=自动生成): " value
    if [[ -n "$value" ]]; then
        [[ "$value" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
            || die "UUID 格式不正确"
        printf '%s\n' "${value,,}"
    else
        gen_uuid
    fi
}

prompt_path() {
    local default="$1" value
    read -rp "XHTTP 路径(留空=/${default}): " value
    [[ -n "$value" ]] || value="/${default}"
    [[ "$value" == /* ]] || value="/$value"
    printf '%s\n' "$value"
}

do_install() {
    [[ ! -f "$STATE_PATH" ]] || die "检测到已有部署，请先卸载"
    check_cloudflared
    [[ -x "$XRAY_BINARY" ]] || install_xray

    local domain port uid path token link config state_json
    read -rp "Tunnel 公开域名: " domain
    [[ "$domain" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "域名格式不正确"

    read -rp "Xray 本地端口(留空=8080): " port
    [[ -n "$port" ]] || port=8080
    validate_port "$port"

    uid=$(prompt_uuid)
    path=$(prompt_path "${uid:0:8}")
    read -rsp "Cloudflare Tunnel Token: " token || die "输入已中断"
    echo
    [[ -n "$token" ]] || die "Tunnel Token 不能为空"

    echo
    echo "请确认 Dashboard 中 Published application 配置为:"
    echo "  Hostname: $domain"
    echo "  Service:  http://127.0.0.1:$port"
    echo "  Path:     留空（XHTTP 路径由 Xray 校验）"
    read -rp "确认继续? (Y/n): " confirm
    [[ "${confirm,,}" =~ ^(|y|yes)$ ]] || die "已取消"

    config=$(gen_xray_config "$port" "$uid" "$path")
    write_xray_config "$config"
    write_file_atomic "$TUNNEL_TOKEN_PATH" 600 "$token"
    unset token

    xray_start
    cloudflared_start

    link=$(build_link "$uid" "$domain" "$path")
    state_json=$(jq -n \
        --arg domain "$domain" --arg uid "$uid" --arg path "$path" \
        --argjson port "$port" --arg link "$link" \
        '{domain:$domain,uuid:$uid,path:$path,local_port:$port,transport:"xhttp",tunnel:true,link:$link}') \
        || die "生成部署状态失败"
    save_state "$state_json"
    write_file_atomic "$LAST_LINKS_PATH" 600 "域名: $domain
UUID: $uid
VLESS XHTTP 节点 $link"

    echo
    ok "部署完成（Xray 仅监听 127.0.0.1:$port）"
    echo "  VLESS XHTTP 节点 $link"
}

do_uninstall() {
    load_existing_state >/dev/null
    cloudflared_stop
    xray_stop
    rm -f "$XRAY_CONFIG_PATH" "$STATE_PATH" "$TUNNEL_TOKEN_PATH" "$LAST_LINKS_PATH"
    ok "已删除本地 Xray/Tunnel 服务配置和 Token"
    info "Dashboard 中的 Tunnel 与 Published application 未删除"
}

do_show() {
    if [[ -f "$LAST_LINKS_PATH" ]]; then
        cat "$LAST_LINKS_PATH"
        return
    fi
    local state
    state=$(load_existing_state)
    echo "$state" | jq -r '"VLESS XHTTP 节点 " + .link'
}

do_modify() {
    local state domain port uid path choice new_uid new_path link config
    state=$(load_existing_state)
    domain=$(echo "$state" | jq -r '.domain')
    port=$(echo "$state" | jq -r '.local_port')
    uid=$(echo "$state" | jq -r '.uuid')
    path=$(echo "$state" | jq -r '.path')

    echo "1. 修改 UUID"
    echo "2. 修改 XHTTP 路径"
    echo "3. 同时修改"
    echo "0. 返回"
    read -rp "请选择 [0-3]: " choice
    [[ "$choice" =~ ^[0-3]$ ]] || die "无效选项"
    [[ "$choice" == 0 ]] && return

    new_uid="$uid"; new_path="$path"
    if [[ "$choice" == 1 || "$choice" == 3 ]]; then
        new_uid=$(prompt_uuid)
    fi
    if [[ "$choice" == 2 || "$choice" == 3 ]]; then
        new_path=$(prompt_path "${new_uid:0:8}")
    fi

    config=$(gen_xray_config "$port" "$new_uid" "$new_path")
    write_xray_config "$config"
    xray_start

    link=$(build_link "$new_uid" "$domain" "$new_path")
    save_state "$(echo "$state" | jq \
        --arg uid "$new_uid" --arg path "$new_path" --arg link "$link" \
        '.uuid=$uid|.path=$path|.link=$link')"
    write_file_atomic "$LAST_LINKS_PATH" 600 "域名: $domain
UUID: $new_uid
VLESS XHTTP 节点 $link"
    ok "配置已更新"
    echo "  VLESS XHTTP 节点 $link"
}

do_show_config() {
    local state
    state=$(load_existing_state)
    echo "$state" | jq -r '
        "域名:       " + .domain,
        "UUID:       " + .uuid,
        "XHTTP 路径: " + .path,
        "本地监听:   127.0.0.1:" + (.local_port|tostring)'
    printf 'xray:              '; xray_is_active && echo "运行中" || echo "未运行"
    printf 'cloudflared-xray:  '; cloudflared_is_active && echo "运行中" || echo "未运行"
}

do_restart() {
    load_existing_state >/dev/null
    check_cloudflared
    xray_start
    cloudflared_start
}

main() {
    [[ "$(id -u)" == 0 ]] || die "请使用 root 运行此脚本"
    detect_init
    install_deps
    need_cmd curl; need_cmd jq

    local current=""
    if [[ -f "$STATE_PATH" ]]; then
        current=$(load_state 2>/dev/null) || die "状态文件损坏: $STATE_PATH"
    fi

    echo
    echo "  xray-cf-lite · Cloudflare Tunnel ($INIT_SYSTEM)"
    echo
    echo "  1. 安装节点"
    echo "  2. 卸载"
    echo "  3. 查看节点链接"
    echo "  4. 修改 UUID/XHTTP 路径"
    echo "  5. 查看当前配置"
    echo "  6. 重启服务"
    [[ -n "$current" ]] && echo "     (当前: $(echo "$current" | jq -r '.domain'))"
    echo

    read -rp "请选择 [1-6]: " choice
    case "$choice" in
        1) do_install ;;
        2) do_uninstall ;;
        3) do_show ;;
        4) do_modify ;;
        5) do_show_config ;;
        6) do_restart ;;
        *) die "无效选项: $choice" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
