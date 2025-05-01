#!/usr/bin/env bash

set -eo pipefail  # 更严格的错误检查

source /etc/profile || true  # 忽略可能的source错误

# 获取基础路径（安全处理路径中的空格和特殊字符）
BASE_PATH=$(cd "$(dirname "$0")" && pwd) || { echo "Get base path failed"; exit 1; }

# 输入参数
Dev=$1
Build_Mod=$2

# 配置文件路径处理
CONFIG_FILE="$BASE_PATH/deconfig/$Dev.config"
INI_FILE="$BASE_PATH/compilecfg/$Dev.ini"

# 检查配置文件存在性
[[ ! -f "$CONFIG_FILE" ]] && { echo "Config not found: $CONFIG_FILE"; exit 1; }
[[ ! -f "$INI_FILE" ]] && { echo "INI file not found: $INI_FILE"; exit 1; }

# 安全读取INI键值（处理键值前后空格和注释）
read_ini_by_key() {
    local key=$1
    awk -F"=" -v target_key="$key" '
        $0 ~ /^[[:space:]]*;/ { next }  # 跳过注释
        $1 ~ /^[[:space:]]*\[/ { next } # 跳过章节头
        {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
            if ($1 == target_key) print $2
        }
    ' "$INI_FILE"
}

# 读取配置参数（带默认值）
REPO_URL=$(read_ini_by_key "REPO_URL") || :
REPO_BRANCH=$(read_ini_by_key "REPO_BRANCH")
REPO_BRANCH=${REPO_BRANCH:-main}
BUILD_DIR=$(read_ini_by_key "BUILD_DIR") || :
COMMIT_HASH=$(read_ini_by_key "COMMIT_HASH")
COMMIT_HASH=${COMMIT_HASH:-none}

# 特殊构建目录处理
[[ -d "$BASE_PATH/action_build" ]] && BUILD_DIR="action_build"

# 更新代码仓库
"$BASE_PATH/update.sh" "$REPO_URL" "$REPO_BRANCH" "$BASE_PATH/$BUILD_DIR" "$COMMIT_HASH"

# 应用配置文件
command cp -f "$CONFIG_FILE" "$BASE_PATH/$BUILD_DIR/.config" || { echo "Copy config failed"; exit 1; }

# 进入构建目录
cd "$BASE_PATH/$BUILD_DIR" || { echo "Enter build dir failed"; exit 1; }
make defconfig || { echo "Make defconfig failed"; exit 1; }

# x86_64架构特殊处理
if grep -qE "^CONFIG_TARGET_x86_64=y" "$CONFIG_FILE"; then
    DISTFEEDS_CONF="package/emortal/default-settings/files/99-distfeeds.conf"
    DISTFEEDS_PATH="$BASE_PATH/$BUILD_DIR/$DISTFEEDS_CONF"
    
    if [[ -d "${DISTFEEDS_PATH%/*}" && -f "$DISTFEEDS_PATH" ]]; then
        sed -i 's/aarch64_cortex-a53/x86_64/g' "$DISTFEEDS_PATH"
    fi
fi

# 调试模式提前退出
[[ "$Build_Mod" == "debug" ]] && exit 0

# 清理旧构建产物
TARGET_DIR="$BASE_PATH/$BUILD_DIR/bin/targets"
[[ -d "$TARGET_DIR" ]] && find "$TARGET_DIR" -type f \
    \( -name "*.bin" -o -name "*.manifest" -o -name "*efi.img.gz" \
    -o -name "*.itb" -o -name "*.fip" -o -name "*.ubi" \
    -o -name "*rootfs.tar.gz" \) -delete

# 并行下载和编译
cpu_cores=$(nproc)
make download -j$((cpu_cores * 2))
{ make -j$((cpu_cores + 1)) || make -j1 V=s; } || { echo "Compilation failed"; exit 1; }

# 收集固件文件
FIRMWARE_DIR="$BASE_PATH/firmware"
rm -rf "$FIRMWARE_DIR"
mkdir -p "$FIRMWARE_DIR"
find "$TARGET_DIR" -type f \
    \( -name "*.bin" -o -name "*.manifest" -o -name "*efi.img.gz" \
    -o -name "*.itb" -o -name "*.fip" -o -name "*.ubi" \
    -o -name "*rootfs.tar.gz" \) -exec cp -f {} "$FIRMWARE_DIR/" \;
rm -f "$FIRMWARE_DIR/Packages.manifest" 2>/dev/null

# 清理中间文件（仅限action_build模式）
[[ -d "$BASE_PATH/action_build" ]] && make clean
