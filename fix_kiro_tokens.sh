#!/bin/bash

# 脚本：为所有 claude-kiro.js 文件添加详细的 token 计算日志
# 功能：在 estimateInputTokens 方法中添加调试日志，不改变原有计算逻辑
# 作者：自动生成
# 日期：2026-01-11

set -e  # 遇到错误立即退出

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 创建备份
backup_file() {
    local file=$1
    local backup="${file}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$file" "$backup"
    log_success "已备份: $backup"
}

# 验证文件是否为 claude-kiro.js
validate_file() {
    local file=$1

    # 检查文件是否包含关键标识
    if grep -q "class KiroApiService" "$file" && \
       grep -q "estimateInputTokens" "$file" && \
       grep -q "countTextTokens" "$file"; then
        return 0
    else
        return 1
    fi
}

# 主修复函数：添加详细的 token 计算日志
add_token_debug_logs() {
    local file=$1

    log_info "添加 token 计算调试日志: $file"

    # 创建临时 Python 脚本进行精确修改
    python3 - "$file" <<'PYTHON_SCRIPT'
import sys
import re

file_path = sys.argv[1]

with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

modifications_made = []

# ============================================================
# 修改：在 estimateInputTokens 方法中添加详细日志
# ============================================================

# 查找原始的 estimateInputTokens 方法
old_pattern = r'''    estimateInputTokens\(requestBody\) \{
        let totalTokens = 0;

        // Count system prompt tokens
        if \(requestBody\.system\) \{
            const systemText = this\.getContentText\(requestBody\.system\);
            totalTokens \+= this\.countTextTokens\(systemText\);
        \}

        // Count all messages tokens
        if \(requestBody\.messages && Array\.isArray\(requestBody\.messages\)\) \{
            for \(const message of requestBody\.messages\) \{
                if \(message\.content\) \{
                    const contentText = this\.getContentText\(message\);
                    totalTokens \+= this\.countTextTokens\(contentText\);
                \}
            \}
        \}

        // Count tools definitions tokens if present
        if \(requestBody\.tools && Array\.isArray\(requestBody\.tools\)\) \{
            totalTokens \+= this\.countTextTokens\(JSON\.stringify\(requestBody\.tools\)\);
        \}

        return totalTokens;
    \}'''

# 新的带详细日志的版本
new_pattern = '''    estimateInputTokens(requestBody) {
        let totalTokens = 0;

        // 用于收集各部分的 token 统计
        const tokenBreakdown = {
            system: 0,
            messages: 0,
            messagesCount: 0,
            tools: 0,
            total: 0
        };

        // Count system prompt tokens
        if (requestBody.system) {
            const systemText = this.getContentText(requestBody.system);
            const systemTokens = this.countTextTokens(systemText);
            tokenBreakdown.system = systemTokens;
            totalTokens += systemTokens;
        }

        // Count all messages tokens
        if (requestBody.messages && Array.isArray(requestBody.messages)) {
            tokenBreakdown.messagesCount = requestBody.messages.length;
            let messagesTotal = 0;
            for (const message of requestBody.messages) {
                if (message.content) {
                    const contentText = this.getContentText(message);
                    const msgTokens = this.countTextTokens(contentText);
                    messagesTotal += msgTokens;
                }
            }
            tokenBreakdown.messages = messagesTotal;
            totalTokens += messagesTotal;
        }

        // Count tools definitions tokens if present
        if (requestBody.tools && Array.isArray(requestBody.tools)) {
            const toolsTokens = this.countTextTokens(JSON.stringify(requestBody.tools));
            tokenBreakdown.tools = toolsTokens;
            totalTokens += toolsTokens;
        }

        tokenBreakdown.total = totalTokens;

        // 输出详细的 token 统计日志
        console.log('[Kiro Token Debug] ========================================');
        console.log('[Kiro Token Debug] Input Tokens Breakdown:');
        console.log(`[Kiro Token Debug]   - System Prompt: ${tokenBreakdown.system} tokens`);
        console.log(`[Kiro Token Debug]   - Messages (${tokenBreakdown.messagesCount} msgs): ${tokenBreakdown.messages} tokens`);
        console.log(`[Kiro Token Debug]   - Tools Definition: ${tokenBreakdown.tools} tokens`);
        console.log(`[Kiro Token Debug]   - TOTAL INPUT: ${tokenBreakdown.total} tokens`);
        console.log('[Kiro Token Debug] ========================================');

        return totalTokens;
    }'''

# 执行替换
if re.search(old_pattern, content, flags=re.MULTILINE | re.DOTALL):
    content = re.sub(old_pattern, new_pattern, content, flags=re.MULTILINE | re.DOTALL)
    modifications_made.append("✓ 已添加 estimateInputTokens 详细日志")
else:
    print("⚠ 未找到标准的 estimateInputTokens 方法，可能文件已被修改或版本不同")

# 写入修改后的内容
with open(file_path, 'w', encoding='utf-8') as f:
    f.write(content)

# 输出修改结果
if modifications_made:
    print("\n修改完成:")
    for mod in modifications_made:
        print(f"  {mod}")
else:
    print("\n⚠ 未进行任何修改，可能文件已经修改过或版本不同")

PYTHON_SCRIPT
}

# 处理单个文件
process_file() {
    local file=$1

    log_info "处理文件: $file"

    # 验证文件
    if ! validate_file "$file"; then
        log_warning "文件验证失败，跳过: $file"
        return 1
    fi

    # 备份文件
    backup_file "$file"

    # 执行修改
    add_token_debug_logs "$file"

    log_success "文件处理完成: $file"
    return 0
}

# 主函数
main() {
    log_info "开始搜索系统中的所有 claude-kiro.js 文件..."

    # 检查 Python3 是否安装
    if ! command -v python3 &> /dev/null; then
        log_error "Python3 未安装，脚本需要 Python3 来执行精确的代码替换"
        exit 1
    fi

    # 搜索所有 claude-kiro.js 文件
    # 排除常见的不需要搜索的目录
    local search_paths=(
        "/home"
        "/opt"
        "/usr/local"
        "/var"
        "/root"
    )

    local exclude_dirs=(
        "node_modules/.pnpm"
        ".git"
        ".cache"
        "tmp"
        "temp"
    )

    # 构建 find 命令的排除参数
    local exclude_args=""
    for dir in "${exclude_dirs[@]}"; do
        exclude_args="$exclude_args -path '*/$dir/*' -prune -o"
    done

    local files_found=0
    local files_processed=0
    local files_failed=0

    log_info "搜索路径: ${search_paths[*]}"

    # 使用 find 命令搜索
    while IFS= read -r -d '' file; do
        files_found=$((files_found + 1))
        log_info "找到文件 #$files_found: $file"

        if process_file "$file"; then
            files_processed=$((files_processed + 1))
        else
            files_failed=$((files_failed + 1))
        fi

        echo "----------------------------------------"
    done < <(find "${search_paths[@]}" $exclude_args -type f -name "claude-kiro.js" -print0 2>/dev/null)

    # 输出统计信息
    echo ""
    log_info "========================================="
    log_info "处理完成统计："
    log_info "找到文件数: $files_found"
    log_success "成功处理: $files_processed"
    if [ $files_failed -gt 0 ]; then
        log_warning "失败/跳过: $files_failed"
    fi
    log_info "========================================="

    if [ $files_found -eq 0 ]; then
        log_warning "未找到任何 claude-kiro.js 文件"
        log_info "提示：请确认文件路径，或手动指定搜索目录"
    fi
}

# 显示帮助信息
show_help() {
    cat << EOF
用法: $0 [选项]

选项:
    -h, --help          显示此帮助信息
    -p, --path PATH     指定搜索路径（可多次使用）
    -f, --file FILE     直接处理指定文件

示例:
    $0                                      # 搜索默认路径
    $0 -p /home/user/projects               # 搜索指定路径
    $0 -f /path/to/claude-kiro.js           # 处理指定文件

说明:
    此脚本会自动搜索系统中的所有 claude-kiro.js 文件，
    并在 estimateInputTokens 方法中添加详细的 token 计算日志。

    添加的日志内容：
    - System Prompt 的 token 数
    - 所有消息的 token 数（包括消息数量）
    - Tools 定义的 token 数
    - 总输入 token 数

    日志格式示例：
    [Kiro Token Debug] ========================================
    [Kiro Token Debug] Input Tokens Breakdown:
    [Kiro Token Debug]   - System Prompt: 5234 tokens
    [Kiro Token Debug]   - Messages (15 msgs): 20145 tokens
    [Kiro Token Debug]   - Tools Definition: 2004 tokens
    [Kiro Token Debug]   - TOTAL INPUT: 27383 tokens
    [Kiro Token Debug] ========================================

    注意：
    - 原有的计算逻辑完全不变
    - 只是添加了详细的日志输出
    - 所有修改前的文件都会自动备份（.backup.时间戳）

EOF
}

# 解析命令行参数
CUSTOM_PATHS=()
SINGLE_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -p|--path)
            CUSTOM_PATHS+=("$2")
            shift 2
            ;;
        -f|--file)
            SINGLE_FILE="$2"
            shift 2
            ;;
        *)
            log_error "未知选项: $1"
            show_help
            exit 1
            ;;
    esac
done

# 执行主逻辑
if [ -n "$SINGLE_FILE" ]; then
    # 处理单个文件
    if [ ! -f "$SINGLE_FILE" ]; then
        log_error "文件不存在: $SINGLE_FILE"
        exit 1
    fi
    process_file "$SINGLE_FILE"
else
    # 搜索并处理所有文件
    if [ ${#CUSTOM_PATHS[@]} -gt 0 ]; then
        # 使用自定义路径
        search_paths=("${CUSTOM_PATHS[@]}")
    fi
    main
fi

log_success "脚本执行完成！"
