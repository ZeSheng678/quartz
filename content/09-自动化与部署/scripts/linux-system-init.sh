#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_VERSION="2.0.5"
BACKUP_ROOT="/var/backups/linux-system-init"
APT_MIRROR="https://mirrors.aliyun.com/ubuntu"
NVM_INSTALL_URL="https://gh-proxy.org/https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.5/install.sh"
NVM_SOURCE_URL="https://gitee.com/mirrors/nvm.git"
NVM_NODEJS_ORG_MIRROR="https://mirrors.huaweicloud.com/nodejs/"
NPM_REGISTRY="https://registry.npmmirror.com"
UV_INSTALL_URL="https://astral.sh/uv/install.sh"
UV_INDEX_URL="http://mirrors.aliyun.com/pypi/simple/"
APT_LOCK_MAX_WAIT=900
APT_LOCK_RETRY_INTERVAL=10

TIMESTAMP=""
TARGET_USER=""
TARGET_HOME=""
DISTRO_ID=""
DISTRO_VERSION=""
DISTRO_CODENAME=""
APT_BACKUP_DIR=""
NETPLAN_BACKUP_DIR=""

CONFIGURE_APT=false
INSTALL_BASE=false
CONFIGURE_NODE=false
CONFIGURE_NPM=false
CONFIGURE_UV=false
NETWORK_ENABLED=false
NETWORK_INTERFACE=""
NETWORK_MODE="keep"
NETWORK_IPV4=""
NETWORK_GATEWAY=""
NETWORK_DNS=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { printf "%b[信息]%b %s\n" "$BLUE" "$NC" "$*"; }
log_ok() { printf "%b[完成]%b %s\n" "$GREEN" "$NC" "$*"; }
log_warn() { printf "%b[警告]%b %s\n" "$YELLOW" "$NC" "$*"; }
log_error() { printf "%b[错误]%b %s\n" "$RED" "$NC" "$*" >&2; }

on_error() {
  local code=$?
  log_error "第 ${BASH_LINENO[0]} 行执行失败，退出码：${code}"
  exit "$code"
}
trap on_error ERR

require_tty() {
  if [[ ! -t 0 ]]; then
    log_error "此脚本是交互式向导，需要在终端中直接运行。"
    exit 1
  fi
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    log_error "请使用 sudo 执行：sudo bash $0"
    exit 1
  fi
}

detect_target_user() {
  local passwd_entry
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    TARGET_USER="$SUDO_USER"
  else
    TARGET_USER="root"
  fi

  passwd_entry="$(getent passwd "$TARGET_USER" || true)"
  if [[ -z "$passwd_entry" ]]; then
    log_error "无法获取目标用户 ${TARGET_USER} 的账户信息。"
    exit 1
  fi

  TARGET_HOME="$(cut -d: -f6 <<< "$passwd_entry")"
  if [[ -z "$TARGET_HOME" || ! -d "$TARGET_HOME" ]]; then
    log_error "目标用户主目录无效：${TARGET_HOME:-空}"
    exit 1
  fi
}

detect_system() {
  if [[ ! -r /etc/os-release ]]; then
    log_error "无法读取 /etc/os-release。"
    exit 1
  fi

  # shellcheck disable=SC1091
  source /etc/os-release
  DISTRO_ID="${ID:-unknown}"
  DISTRO_VERSION="${VERSION_ID:-unknown}"
  DISTRO_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-unknown}}"

  if [[ "$DISTRO_ID" != "ubuntu" || "$DISTRO_CODENAME" == "unknown" ]]; then
    log_error "当前版本只支持 Ubuntu，检测到：${DISTRO_ID} ${DISTRO_VERSION}"
    exit 1
  fi
}

yes_no() {
  local prompt="$1"
  local default="${2:-y}"
  local answer hint="[Y/n]"
  [[ "$default" == "n" ]] && hint="[y/N]"

  while true; do
    read -r -p "${prompt} ${hint}: " answer
    answer="${answer:-$default}"
    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) echo "请输入 y 或 n。" ;;
    esac
  done
}

choose_from_menu() {
  local prompt="$1"
  local max="$2"
  local choice
  while true; do
    read -r -p "$prompt" choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 0 && choice <= max)); then
      REPLY="$choice"
      return 0
    fi
    echo "请输入 0-${max} 之间的数字。"
  done
}

run_as_target_shell() {
  local command="$1"
  if [[ "$TARGET_USER" == "root" ]]; then
    HOME="$TARGET_HOME" USER="$TARGET_USER" bash -o pipefail -c "$command"
  else
    runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" USER="$TARGET_USER" \
      bash -o pipefail -c "$command"
  fi
}

run_apt_get() {
  local started_at=$SECONDS attempt=0 status=0 elapsed=0
  local holder_pid="" holder_name="" output_file=""

  while true; do
    ((attempt += 1))
    output_file="$(mktemp)"

    set +e
    DEBIAN_FRONTEND=noninteractive apt-get "$@" 2>&1 | tee "$output_file"
    status=${PIPESTATUS[0]}
    set -e

    if ((status == 0)); then
      rm -f "$output_file"
      return 0
    fi

    if ! grep -Eq 'Could not get lock|Unable to acquire|lock-frontend|/var/lib/apt/lists/lock|/var/cache/apt/archives/lock|is another process using it' "$output_file"; then
      rm -f "$output_file"
      return "$status"
    fi

    holder_pid="$(grep -Eo 'process [0-9]+' "$output_file" | head -n 1 | awk '{print $2}' || true)"
    holder_name=""
    if [[ -n "$holder_pid" ]] && kill -0 "$holder_pid" 2>/dev/null; then
      holder_name="$(ps -p "$holder_pid" -o comm= 2>/dev/null | xargs || true)"
    fi
    rm -f "$output_file"

    elapsed=$((SECONDS - started_at))
    if ((elapsed >= APT_LOCK_MAX_WAIT)); then
      log_error "等待 APT/dpkg 锁超过 $((APT_LOCK_MAX_WAIT / 60)) 分钟，已安全停止。"
      log_error "请等待自动更新完成后重新运行脚本；不要删除任何 lock 文件。"
      return 75
    fi

    if [[ -n "$holder_pid" ]]; then
      log_warn "APT/dpkg 正被进程 ${holder_pid}${holder_name:+ (${holder_name})} 使用。"
    else
      log_warn "APT/dpkg 正被其他系统任务使用。"
    fi
    log_info "${APT_LOCK_RETRY_INTERVAL} 秒后自动重试（已等待 ${elapsed} 秒）……"
    sleep "$APT_LOCK_RETRY_INTERVAL"
  done
}

base_tools_complete() {
  [[ -r /etc/ssl/certs/ca-certificates.crt ]] || return 1
  command -v curl >/dev/null 2>&1 || return 1
  command -v git >/dev/null 2>&1 || return 1
  command -v gpg >/dev/null 2>&1 || return 1
  command -v gcc >/dev/null 2>&1 || return 1
  command -v g++ >/dev/null 2>&1 || return 1
  command -v make >/dev/null 2>&1 || return 1
  command -v unzip >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
}

nvm_installed() {
  [[ -s "${TARGET_HOME}/.nvm/nvm.sh" ]] || return 1
  run_as_target_shell 'unset NPM_CONFIG_PREFIX PREFIX; export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"; command -v nvm >/dev/null 2>&1' \
    >/dev/null 2>&1
}

nvm_mirror_configured() {
  grep -Fqx "export NVM_NODEJS_ORG_MIRROR=${NVM_NODEJS_ORG_MIRROR}" \
    "${TARGET_HOME}/.bashrc" 2>/dev/null
}

nvm_lts_version() {
  nvm_installed || return 1
  run_as_target_shell 'unset NPM_CONFIG_PREFIX PREFIX; export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"; nvm version "lts/*"' \
    2>/dev/null
}

nvm_node_complete() {
  local version=""
  nvm_installed || return 1
  nvm_mirror_configured || return 1
  version="$(nvm_lts_version || true)"
  [[ -n "$version" && "$version" != "N/A" && "$version" != "system" ]]
}

npm_registry_configured() {
  grep -Eq "^[[:space:]]*registry[[:space:]]*=[[:space:]]*${NPM_REGISTRY}/?[[:space:]]*$" \
    "${TARGET_HOME}/.npmrc" 2>/dev/null
}

uv_path() {
  local candidate
  for candidate in \
    "${TARGET_HOME}/.local/bin/uv" \
    "${TARGET_HOME}/.cargo/bin/uv" \
    "/usr/local/bin/uv"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  if command -v uv >/dev/null 2>&1; then
    command -v uv
    return 0
  fi
  return 1
}

uv_index_configured() {
  local config_file="${TARGET_HOME}/.config/uv/uv.toml"
  grep -Fq "url = \"${UV_INDEX_URL}\"" "$config_file" 2>/dev/null &&
    grep -Fq 'allow-insecure-host = ["mirrors.aliyun.com"]' "$config_file" 2>/dev/null
}

uv_environment_complete() {
  uv_path >/dev/null 2>&1 && uv_index_configured
}

valid_ipv4() {
  local ip="$1" part
  local IFS='.'
  local -a parts
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  read -r -a parts <<< "$ip"
  [[ ${#parts[@]} -eq 4 ]] || return 1
  for part in "${parts[@]}"; do
    ((10#$part >= 0 && 10#$part <= 255)) || return 1
  done
}

valid_cidr() {
  local value="$1" ip prefix
  ip="${value%/*}"
  prefix="${value#*/}"
  [[ "$value" == */* ]] || return 1
  valid_ipv4 "$ip" || return 1
  [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
  ((prefix >= 0 && prefix <= 32))
}

valid_dns_list() {
  local value="$1" item
  local IFS=','
  local -a items
  read -r -a items <<< "$value"
  [[ ${#items[@]} -gt 0 ]] || return 1
  for item in "${items[@]}"; do
    item="${item//[[:space:]]/}"
    valid_ipv4 "$item" || return 1
  done
}

choose_network() {
  NETWORK_ENABLED=false
  NETWORK_MODE="keep"
  echo
  if ! yes_no "是否配置 IPv4 网络？高风险，默认跳过" n; then
    log_info "网络配置保持不变。"
    return
  fi

  if ! command -v netplan >/dev/null 2>&1 || [[ ! -d /etc/netplan ]]; then
    log_warn "未检测到 Netplan，网络模块已跳过。"
    return
  fi

  local -a interfaces
  mapfile -t interfaces < <(find /sys/class/net -mindepth 1 -maxdepth 1 -printf '%f\n' | grep -v '^lo$' | sort)
  if [[ ${#interfaces[@]} -eq 0 ]]; then
    log_warn "没有检测到可配置网卡，网络模块已跳过。"
    return
  fi

  echo "检测到以下网卡："
  local i
  for i in "${!interfaces[@]}"; do
    printf "[%d] %s" "$((i + 1))" "${interfaces[$i]}"
    if command -v ip >/dev/null 2>&1; then
      printf "  %s" "$(ip -4 -o addr show dev "${interfaces[$i]}" 2>/dev/null | awk '{print $4}' | paste -sd ',' -)"
    fi
    printf "\n"
  done
  echo "[0] 跳过"
  choose_from_menu "请选择网卡：" "${#interfaces[@]}"
  if [[ "$REPLY" == "0" ]]; then
    log_info "网络配置保持不变。"
    return
  fi
  NETWORK_INTERFACE="${interfaces[$((REPLY - 1))]}"
  log_info "已选择网卡 ${NETWORK_INTERFACE}。"

  echo "[1] DHCP"
  echo "[2] 静态 IPv4"
  echo "[0] 跳过"
  choose_from_menu "请选择网络模式：" 2
  case "$REPLY" in
    0) log_info "网络配置保持不变。"; return ;;
    1) NETWORK_MODE="dhcp" ;;
    2) NETWORK_MODE="static" ;;
  esac

  if [[ "$NETWORK_MODE" == "static" ]]; then
    while true; do
      read -r -p "请输入 IPv4/CIDR（例如 192.168.1.50/24）：" NETWORK_IPV4
      valid_cidr "$NETWORK_IPV4" && break
      echo "IPv4/CIDR 格式无效。"
    done
    while true; do
      read -r -p "请输入默认网关（例如 192.168.1.1）：" NETWORK_GATEWAY
      valid_ipv4 "$NETWORK_GATEWAY" && break
      echo "网关地址无效。"
    done
    log_info "将为 ${NETWORK_INTERFACE} 设置 ${NETWORK_IPV4}，网关 ${NETWORK_GATEWAY}。"
  else
    log_info "将把 ${NETWORK_INTERFACE} 配置为 DHCP。"
  fi

  echo "[1] 阿里 DNS（223.5.5.5,223.6.6.6）"
  echo "[2] 腾讯 DNSPod（119.29.29.29,182.254.116.116）"
  echo "[3] Cloudflare（1.1.1.1,1.0.0.1）"
  echo "[4] Google（8.8.8.8,8.8.4.4）"
  echo "[5] 自定义"
  if [[ "$NETWORK_MODE" == "dhcp" ]]; then
    echo "[6] 沿用 DHCP 自动 DNS"
    choose_from_menu "请选择 DNS：" 6
  else
    choose_from_menu "请选择 DNS：" 5
  fi
  case "$REPLY" in
    1) NETWORK_DNS="223.5.5.5,223.6.6.6" ;;
    2) NETWORK_DNS="119.29.29.29,182.254.116.116" ;;
    3) NETWORK_DNS="1.1.1.1,1.0.0.1" ;;
    4) NETWORK_DNS="8.8.8.8,8.8.4.4" ;;
    5)
      while true; do
        read -r -p "请输入 DNS，多个地址用英文逗号分隔：" NETWORK_DNS
        valid_dns_list "$NETWORK_DNS" && break
        echo "DNS 地址列表无效。"
      done
      ;;
    6) NETWORK_DNS="" ;;
  esac
  NETWORK_ENABLED=true
  if [[ -n "$NETWORK_DNS" ]]; then
    log_info "将使用 DNS：${NETWORK_DNS}。"
  else
    log_info "将沿用 DHCP 自动分配的 DNS。"
  fi
}

collect_plan() {
  clear
  echo "Linux 系统初始化工具 v${SCRIPT_VERSION}"
  echo "系统：${DISTRO_ID} ${DISTRO_VERSION} (${DISTRO_CODENAME})"
  echo "目标用户：${TARGET_USER} (${TARGET_HOME})"
  echo
  echo "脚本将逐项询问，每个模块都可以跳过。"

  echo
  if yes_no "是否将 APT 软件源固定为阿里云？" y; then
    CONFIGURE_APT=true
    log_warn "将备份并清除现有 APT 源，仅写入 ${APT_MIRROR}。"
  else
    log_info "APT 软件源保持不变。"
  fi

  echo
  if base_tools_complete; then
    log_info "基础工具已全部安装，不再重复安装。"
  elif yes_no "是否安装缺失的基础工具？" y; then
    INSTALL_BASE=true
    log_info "将补齐：ca-certificates、curl、git、gnupg、build-essential、unzip、jq。"
  else
    log_info "基础工具缺失项保持不变。"
  fi

  echo
  if nvm_node_complete; then
    log_info "NVM、华为云 Node.js 镜像变量和默认 Node.js 已配置，不再重复安装。"
  elif yes_no "是否配置 NVM 并安装一个 Node.js LTS 版本？" y; then
    CONFIGURE_NODE=true
    log_info "将通过 Gitee 下载 NVM v0.40.5，写入华为云镜像变量，并安装缺失的默认 LTS。"
  else
    log_info "NVM 和 Node.js 保持不变。"
  fi

  echo
  if npm_registry_configured; then
    log_info "npm Registry 已是 ${NPM_REGISTRY}，不再修改。"
  elif yes_no "是否将 npm Registry 固定为 npmmirror？" y; then
    CONFIGURE_NPM=true
    log_info "将把 ${TARGET_HOME}/.npmrc 的 Registry 设置为 ${NPM_REGISTRY}。"
  else
    log_info "npm Registry 保持不变。"
  fi

  echo
  if uv_environment_complete; then
    log_info "uv 和阿里云 Python 索引已经配置，不再重复安装。"
  elif yes_no "是否安装 uv 并配置阿里云 Python 索引？" y; then
    CONFIGURE_UV=true
    log_info "将安装缺失的 uv，并写入索引 ${UV_INDEX_URL}。"
  else
    log_info "uv 和 Python 包索引保持不变。"
  fi

  choose_network
}

print_summary() {
  echo
  echo "================ 执行计划 ================"
  echo "APT：$([[ "$CONFIGURE_APT" == true ]] && echo "仅保留阿里云 Ubuntu 源" || echo "跳过")"
  echo "基础工具：$([[ "$INSTALL_BASE" == true ]] && echo "安装缺失项" || echo "跳过")"
  echo "NVM/Node.js：$([[ "$CONFIGURE_NODE" == true ]] && echo "通过 Gitee 配置 NVM v0.40.5 和默认 LTS" || echo "跳过")"
  echo "npm Registry：$([[ "$CONFIGURE_NPM" == true ]] && echo "$NPM_REGISTRY" || echo "跳过")"
  echo "uv/Python 索引：$([[ "$CONFIGURE_UV" == true ]] && echo "$UV_INDEX_URL" || echo "跳过")"
  if [[ "$NETWORK_ENABLED" == true ]]; then
    echo "网络：${NETWORK_INTERFACE} / ${NETWORK_MODE}"
    [[ -n "$NETWORK_IPV4" ]] && echo "IPv4：${NETWORK_IPV4}"
    [[ -n "$NETWORK_GATEWAY" ]] && echo "网关：${NETWORK_GATEWAY}"
    [[ -n "$NETWORK_DNS" ]] && echo "DNS：${NETWORK_DNS}"
  else
    echo "网络：跳过"
  fi
  echo "=========================================="
}

backup_apt_sources() {
  APT_BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}/apt"
  mkdir -p "$APT_BACKUP_DIR"
  [[ -f /etc/apt/sources.list ]] && cp -a /etc/apt/sources.list "$APT_BACKUP_DIR/"
  [[ -d /etc/apt/sources.list.d ]] && cp -a /etc/apt/sources.list.d "$APT_BACKUP_DIR/"
  log_ok "APT 配置已备份到 ${APT_BACKUP_DIR}"
}

restore_apt_sources() {
  [[ -d "$APT_BACKUP_DIR" ]] || return 1
  rm -f /etc/apt/sources.list
  rm -rf /etc/apt/sources.list.d
  [[ -f "$APT_BACKUP_DIR/sources.list" ]] && cp -a "$APT_BACKUP_DIR/sources.list" /etc/apt/
  if [[ -d "$APT_BACKUP_DIR/sources.list.d" ]]; then
    cp -a "$APT_BACKUP_DIR/sources.list.d" /etc/apt/
  else
    mkdir -p /etc/apt/sources.list.d
  fi
  log_ok "APT 配置已从 ${APT_BACKUP_DIR} 恢复。"
}

apply_apt_source() {
  [[ "$CONFIGURE_APT" == true ]] || return 0
  backup_apt_sources

  rm -f /etc/apt/sources.list
  find /etc/apt/sources.list.d -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  cat > /etc/apt/sources.list.d/aliyun.sources <<EOF
Types: deb
URIs: ${APT_MIRROR}
Suites: ${DISTRO_CODENAME} ${DISTRO_CODENAME}-updates ${DISTRO_CODENAME}-backports ${DISTRO_CODENAME}-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
  chmod 0644 /etc/apt/sources.list.d/aliyun.sources

  if run_apt_get update; then
    log_ok "APT 已固定为 ${APT_MIRROR}"
    return 0
  fi

  log_error "阿里云 APT 源不可用，正在恢复原配置。"
  restore_apt_sources
  run_apt_get update || log_warn "原 APT 配置恢复后仍无法更新，请检查网络和 DNS。"
  return 1
}

install_base_tools() {
  [[ "$INSTALL_BASE" == true || "$CONFIGURE_NODE" == true || "$CONFIGURE_UV" == true ]] || return 0
  local -a packages=()

  [[ -r /etc/ssl/certs/ca-certificates.crt ]] || packages+=(ca-certificates)
  command -v curl >/dev/null 2>&1 || packages+=(curl)
  if [[ "$INSTALL_BASE" == true ]]; then
    command -v git >/dev/null 2>&1 || packages+=(git)
    command -v gpg >/dev/null 2>&1 || packages+=(gnupg)
    if ! command -v gcc >/dev/null 2>&1 || ! command -v g++ >/dev/null 2>&1 || ! command -v make >/dev/null 2>&1; then
      packages+=(build-essential)
    fi
    command -v unzip >/dev/null 2>&1 || packages+=(unzip)
    command -v jq >/dev/null 2>&1 || packages+=(jq)
  fi
  if [[ "$CONFIGURE_NODE" == true || "$CONFIGURE_UV" == true ]]; then
    command -v gzip >/dev/null 2>&1 || packages+=(gzip)
    command -v tar >/dev/null 2>&1 || packages+=(tar)
  fi

  if [[ ${#packages[@]} -eq 0 ]]; then
    log_info "基础工具和安装依赖已存在，跳过安装。"
    return
  fi

  run_apt_get update
  run_apt_get install -y "${packages[@]}"
  log_ok "已补齐：${packages[*]}"
}

configure_nvm_mirror() {
  local bashrc="${TARGET_HOME}/.bashrc"
  local backup_dir="${BACKUP_ROOT}/${TIMESTAMP}/nvm"
  mkdir -p "$backup_dir"
  [[ -f "$bashrc" ]] && cp -a "$bashrc" "$backup_dir/bashrc"
  touch "$bashrc"

  if grep -Eq '^[[:space:]]*export[[:space:]]+NVM_NODEJS_ORG_MIRROR=' "$bashrc"; then
    sed -i -E "s#^[[:space:]]*export[[:space:]]+NVM_NODEJS_ORG_MIRROR=.*#export NVM_NODEJS_ORG_MIRROR=${NVM_NODEJS_ORG_MIRROR}#" "$bashrc"
  else
    printf '\nexport NVM_NODEJS_ORG_MIRROR=%s\n' "$NVM_NODEJS_ORG_MIRROR" >> "$bashrc"
  fi
  chown "$TARGET_USER:" "$bashrc"
  log_ok "已写入 NVM_NODEJS_ORG_MIRROR=${NVM_NODEJS_ORG_MIRROR}"
}

backup_user_npm_config() {
  local config_file="${TARGET_HOME}/.npmrc"
  local backup_dir="${BACKUP_ROOT}/${TIMESTAMP}/npm"
  mkdir -p "$backup_dir"
  if [[ -f "$config_file" && ! -f "$backup_dir/npmrc" ]]; then
    cp -a "$config_file" "$backup_dir/npmrc"
  fi
}

sanitize_npm_config_for_nvm() {
  local config_file="${TARGET_HOME}/.npmrc"
  [[ -f "$config_file" ]] || return 0
  if grep -Eq '^[[:space:]]*(prefix|globalconfig)[[:space:]]*=' "$config_file"; then
    backup_user_npm_config
    sed -i -E '/^[[:space:]]*(prefix|globalconfig)[[:space:]]*=/d' "$config_file"
    chown "$TARGET_USER:" "$config_file"
    log_warn "已备份并移除 ~/.npmrc 中与 NVM 冲突的 prefix/globalconfig。"
  fi
}

install_nvm_node() {
  [[ "$CONFIGURE_NODE" == true ]] || return 0

  sanitize_npm_config_for_nvm

  if nvm_installed; then
    log_info "检测到现有 NVM $(run_as_target_shell 'unset NPM_CONFIG_PREFIX PREFIX; export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"; nvm --version')，跳过 NVM 安装。"
  else
    local invalid_nvm_backup="${BACKUP_ROOT}/${TIMESTAMP}/nvm/invalid-nvm"
    if [[ -e "${TARGET_HOME}/.nvm" ]]; then
      mkdir -p "$(dirname "$invalid_nvm_backup")"
      mv "${TARGET_HOME}/.nvm" "$invalid_nvm_backup"
      log_warn "检测到不可用的 NVM 目录，已移至 ${invalid_nvm_backup}"
    fi

    local legacy_node_path="" legacy_node_version=""
    legacy_node_path="$(command -v node 2>/dev/null || command -v nodejs 2>/dev/null || true)"
    if [[ -n "$legacy_node_path" && "$legacy_node_path" != "${TARGET_HOME}/.nvm/"* ]]; then
      legacy_node_version="$($legacy_node_path --version 2>/dev/null || echo 未知版本)"
      log_warn "检测到旧系统 Node.js ${legacy_node_version}（${legacy_node_path}），将保留；加载 NVM 后由 LTS 版本优先接管。"
    fi

    log_info "NVM Git 仓库：${NVM_SOURCE_URL}"
    log_info "将以 METHOD=git 执行：curl -fsSL ${NVM_INSTALL_URL} | bash"
    run_as_target_shell 'export PATH=/usr/bin:/bin; unset NPM_CONFIG_PREFIX PREFIX; export PROFILE="$HOME/.bashrc"; export METHOD=git; export NVM_SOURCE="https://gitee.com/mirrors/nvm.git"; curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.5/install.sh | bash'
    if ! nvm_installed; then
      log_error "NVM 安装完成后未找到 ${TARGET_HOME}/.nvm/nvm.sh"
      return 1
    fi
  fi

  configure_nvm_mirror

  local lts_version=""
  lts_version="$(nvm_lts_version || true)"
  if [[ -n "$lts_version" && "$lts_version" != "N/A" && "$lts_version" != "system" ]]; then
    log_info "检测到 NVM 管理的 Node.js LTS ${lts_version}，不再重复安装。"
  else
    run_as_target_shell 'unset NPM_CONFIG_PREFIX PREFIX; export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"; export NVM_NODEJS_ORG_MIRROR=https://mirrors.huaweicloud.com/nodejs/; nvm install "lts/*"; nvm alias default "lts/*"; nvm use default'
  fi

  run_as_target_shell 'unset NPM_CONFIG_PREFIX PREFIX; export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"; nvm alias default "lts/*" >/dev/null; nvm use default >/dev/null'

  run_as_target_shell 'unset NPM_CONFIG_PREFIX PREFIX; export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"; nvm use default >/dev/null; printf "NVM：%s\nNode.js：%s\nnpm：%s\nNode 路径：%s\n" "$(nvm --version)" "$(node --version)" "$(npm --version)" "$(command -v node)"'
}

apply_npm_registry() {
  [[ "$CONFIGURE_NPM" == true ]] || return 0
  local config_file="${TARGET_HOME}/.npmrc"
  backup_user_npm_config

  if [[ -f "$config_file" ]] && grep -Eq '^[[:space:]]*registry[[:space:]]*=' "$config_file"; then
    sed -i -E "s#^[[:space:]]*registry[[:space:]]*=.*#registry=${NPM_REGISTRY}#" "$config_file"
  elif [[ -s "$config_file" ]]; then
    printf '\nregistry=%s\n' "$NPM_REGISTRY" >> "$config_file"
  else
    printf 'registry=%s\n' "$NPM_REGISTRY" > "$config_file"
  fi
  chown "$TARGET_USER:" "$config_file"
  chmod 0600 "$config_file"
  log_ok "npm Registry 已设置为 ${NPM_REGISTRY}"
}

install_and_configure_uv() {
  [[ "$CONFIGURE_UV" == true ]] || return 0
  local command_path="" config_file backup_dir target_group

  if command_path="$(uv_path)"; then
    log_info "检测到 $($command_path --version)，跳过 uv 安装。"
  else
    log_info "将执行：curl -LsSf ${UV_INSTALL_URL} | sh"
    run_as_target_shell 'curl -LsSf https://astral.sh/uv/install.sh | sh'
    command_path="$(uv_path || true)"
    if [[ -z "$command_path" ]]; then
      log_error "uv 安装完成后未找到可执行文件。"
      return 1
    fi
  fi

  config_file="${TARGET_HOME}/.config/uv/uv.toml"
  backup_dir="${BACKUP_ROOT}/${TIMESTAMP}/uv"
  target_group="$(id -gn "$TARGET_USER")"
  mkdir -p "$backup_dir"
  [[ -f "$config_file" ]] && cp -a "$config_file" "$backup_dir/uv.toml"
  install -d -m 0755 -o "$TARGET_USER" -g "$target_group" "$(dirname "$config_file")"
  cat > "$config_file" <<EOF
allow-insecure-host = ["mirrors.aliyun.com"]

[[index]]
name = "aliyun"
url = "${UV_INDEX_URL}"
default = true
EOF
  chown "$TARGET_USER:$target_group" "$config_file"
  chmod 0644 "$config_file"

  local env_file="${TARGET_HOME}/.local/bin/env"
  local bashrc="${TARGET_HOME}/.bashrc"
  local shell_backup_dir="${BACKUP_ROOT}/${TIMESTAMP}/shell"
  local env_source_line='[ -f "$HOME/.local/bin/env" ] && source "$HOME/.local/bin/env"'
  install -d -m 0755 -o "$TARGET_USER" -g "$target_group" "$(dirname "$env_file")"
  if [[ ! -f "$env_file" ]]; then
    cat > "$env_file" <<'EOF'
case ":${PATH}:" in
  *:"${HOME}/.local/bin":*) ;;
  *) export PATH="${HOME}/.local/bin:${PATH}" ;;
esac
EOF
    chown "$TARGET_USER:$target_group" "$env_file"
    chmod 0644 "$env_file"
  fi

  touch "$bashrc"
  if ! grep -Fqx "$env_source_line" "$bashrc"; then
    mkdir -p "$shell_backup_dir"
    [[ -s "$bashrc" ]] && cp -a "$bashrc" "$shell_backup_dir/bashrc"
    printf '\n%s\n' "$env_source_line" >> "$bashrc"
    chown "$TARGET_USER:$target_group" "$bashrc"
  fi
  log_ok "$($command_path --version) 已安装，Python 索引已设置为 ${UV_INDEX_URL}"
}

print_activation_instructions() {
  echo
  log_info "请回到原来的 ${TARGET_USER} 终端执行以下命令，使环境立即生效："
  echo 'source "$HOME/.local/bin/env"'
  echo 'source "$HOME/.bashrc"'
}

restore_netplan() {
  [[ -n "$NETPLAN_BACKUP_DIR" && -d "$NETPLAN_BACKUP_DIR" ]] || return 1
  find /etc/netplan -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  cp -a "$NETPLAN_BACKUP_DIR"/. /etc/netplan/
  netplan generate
  log_ok "Netplan 配置已恢复。"
}

apply_network() {
  [[ "$NETWORK_ENABLED" == true ]] || return 0
  local config_file="/etc/netplan/99-linux-system-init.yaml"
  local dns_yaml=""
  NETPLAN_BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}/netplan"
  mkdir -p "$NETPLAN_BACKUP_DIR"
  cp -a /etc/netplan/. "$NETPLAN_BACKUP_DIR/"

  [[ -n "$NETWORK_DNS" ]] && dns_yaml="${NETWORK_DNS//,/, }"
  if [[ "$NETWORK_MODE" == "dhcp" ]]; then
    cat > "$config_file" <<EOF
network:
  version: 2
  ethernets:
    ${NETWORK_INTERFACE}:
      dhcp4: true
EOF
    if [[ -n "$dns_yaml" ]]; then
      cat >> "$config_file" <<EOF
      dhcp4-overrides:
        use-dns: false
      nameservers:
        addresses: [${dns_yaml}]
EOF
    fi
  else
    cat > "$config_file" <<EOF
network:
  version: 2
  ethernets:
    ${NETWORK_INTERFACE}:
      dhcp4: false
      addresses: [${NETWORK_IPV4}]
      routes:
        - to: default
          via: ${NETWORK_GATEWAY}
      nameservers:
        addresses: [${dns_yaml}]
EOF
  fi
  chmod 0600 "$config_file"

  if ! netplan generate; then
    log_error "Netplan 语法检查失败，正在恢复备份。"
    restore_netplan
    return 1
  fi

  log_warn "应用网络配置可能中断 SSH。"
  if yes_no "现在执行 netplan try（60 秒自动回滚）？" n; then
    if netplan try --timeout 60; then
      log_ok "网络配置已确认。"
    else
      log_warn "网络配置未确认或应用失败，正在恢复磁盘中的原配置。"
      restore_netplan
      return 1
    fi
  else
    log_warn "已取消网络变更，正在恢复原配置，避免重启后意外生效。"
    restore_netplan
  fi
}

verify_installation() {
  echo
  echo "================ 执行结果 ================"
  echo "脚本版本：${SCRIPT_VERSION}"
  echo "APT：$([[ -f /etc/apt/sources.list.d/aliyun.sources ]] && echo "$APT_MIRROR" || echo "未由本次脚本固定")"
  if nvm_installed; then
    run_as_target_shell 'unset NPM_CONFIG_PREFIX PREFIX; export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"; nvm use default >/dev/null 2>&1 || true; printf "NVM：%s\nNode.js：%s\nnpm：%s\nNode 路径：%s\n" "$(nvm --version)" "$(node --version 2>/dev/null || echo 未安装)" "$(npm --version 2>/dev/null || echo 未安装)" "$(command -v node 2>/dev/null || echo 未安装)"'
  else
    echo "NVM：未安装"
  fi
  if npm_registry_configured; then
    echo "npm Registry：${NPM_REGISTRY}"
  else
    echo "npm Registry：未由本次脚本固定"
  fi
  local installed_uv=""
  installed_uv="$(uv_path || true)"
  [[ -n "$installed_uv" ]] && echo "uv：$($installed_uv --version)" || echo "uv：未安装"
  [[ -f "${TARGET_HOME}/.config/uv/uv.toml" ]] && echo "uv Index：${UV_INDEX_URL}"
  command -v ip >/dev/null 2>&1 && echo "默认路由：$(ip route show default | head -n 1)"
  echo "备份目录：${BACKUP_ROOT}/${TIMESTAMP}"
  echo "=========================================="
}

main() {
  require_tty
  require_root
  detect_target_user
  detect_system
  collect_plan
  print_summary

  if ! yes_no "确认执行以上计划？" n; then
    log_warn "已取消，系统未做改动。"
    return
  fi

  TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "${BACKUP_ROOT}/${TIMESTAMP}"
  apply_apt_source
  install_base_tools
  install_nvm_node
  apply_npm_registry
  install_and_configure_uv
  apply_network
  verify_installation
  log_ok "初始化流程完成。"
  print_activation_instructions
}

main "$@"
