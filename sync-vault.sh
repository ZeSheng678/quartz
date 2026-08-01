#!/bin/bash
# sync-vault.sh — 从 Obsidian vault 同步公开内容到 Quartz
# 用法: ./sync-vault.sh

set -e

# ========== 配置 ==========
VAULT_DIR="$HOME/obsidian-vault"
QUARTZ_DIR="$HOME/quartz-demo"
PROXY="http://192.168.71.212:7890"

# 要同步的目录（vault 路径 → quartz 目标名）
# 不想同步的目录在下面注释掉即可
SYNC_DIRS=(
    "00-索引"
    "07-命令速查"
    "08-故障复盘"
    "09-自动化与部署"
    "000Linux学习札记"
)

# 需要排除的文件（在 SYNC_DIRS 中匹配）
EXCLUDE_FILES=(
    "个人局域网环境.md"
    #"系统监控"
    #"Awesome"
    #"Hermes"
)

# ========== 函数 ==========
log() { echo -e "\033[36m→ $*\033[0m"; }
ok()  { echo -e "\033[32m✅ $*\033[0m"; }
err() { echo -e "\033[31m❌ $*\033[0m"; }

# ========== 1. 拉取最新 vault ==========
log "================$(date +'%y-%m-%d %H:%M:%S')==================="
log "拉取 quartz 最新内容"
cd "$QUARTZ_DIR" || exit 1
git pull --quiet origin main

log "拉取 obsidian-vault 最新内容..."
cd "$VAULT_DIR" || exit 1
git fetch origin
REMOTE_NEW=$(git log HEAD..origin/main --oneline)

# 检查是否有变更
if [[ -n "$REMOTE_NEW" ]]; then
    git pull --quiet origin main
    ok "vault 已更新到 $(git log -1 --format='%h %s')"
    echo "$REMOTE_NEW"
else
    ok "vault没有变更，提前结束"
    exit 0
fi

# ========== 2. 同步目录到 Quartz content ==========
log "同步 ${#SYNC_DIRS[@]} 个目录到 Quartz..."

# 先清理旧内容（保留 index.md 和 .gitkeep）
for dir in "${SYNC_DIRS[@]}"; do
    target="$QUARTZ_DIR/content/$dir"
    if [ -d "$target" ]; then
        rm -rf "$target"
    fi
done

# 复制目录
for dir in "${SYNC_DIRS[@]}"; do
    src="$VAULT_DIR/$dir"
    dst="$QUARTZ_DIR/content/$dir"
    
    if [ ! -d "$src" ]; then
        err "源目录不存在: $src"
        continue
    fi
    
    cp -r "$src" "$dst"
    
    # 排除敏感文件
    for pattern in "${EXCLUDE_FILES[@]}"; do
        find "$dst" -type f -name "*${pattern}*" -delete 2>/dev/null || true
        find "$dst" -type d -name "*${pattern}*" -exec rm -rf {} + 2>/dev/null || true
    done
    
    count=$(find "$dst" -name "*.md" | wc -l)
    ok "$dir → $count 篇"
done

# ========== 3. 提交并推送 ==========
log "提交并推送..."
cd "$QUARTZ_DIR"

# 检查是否有变更
if git diff --quiet && git diff --cached --quiet; then
    ok "没有变更，跳过推送"
    exit 0
fi

git add -A
git commit -m "sync: $(date '+%Y-%m-%d %H:%M') vault update"

# 使用代理推送
git -c http.proxy="$PROXY" -c https.proxy="$PROXY" push

ok "推送成功！Actions 自动部署中..."
echo "🌐 访问: https://ZeSheng678.github.io/quartz/"
