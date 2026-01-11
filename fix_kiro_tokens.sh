#!/bin/bash

# 脚本：修复所有 claude-kiro.js 文件中的 outtokens 计算逻辑
# 功能：优先使用 Claude 官方 tokenizer，失败则回退到 contextUsagePercentage
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
       grep -q "buildClaudeResponse" "$file" && \
       grep -q "generateContentStream" "$file" && \
       grep -q "countTokens" "$file"; then
        return 0
    else
        return 1
    fi
}

# 主修复函数：修改流式和非流式的 token 计算逻辑
fix_token_calculation() {
    local file=$1

    log_info "修复 token 计算逻辑（优先 tokenizer，回退 contextUsagePercentage）: $file"

    # 创建临时 Python 脚本进行精确修改
    python3 - "$file" <<'PYTHON_SCRIPT'
import sys
import re

file_path = sys.argv[1]

with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

modifications_made = []

# ============================================================
# 修改 1: 流式响应 - generateContentStream 方法
# ============================================================
old_streaming_pattern = r'''            // 6\. 发送 message_delta 事件
            // 如果有 contextUsagePercentage，使用它来计算 token
            // 总上下文 200k tokens，通过百分比计算总使用量，再减去输入 token 得到输出 token
            let totalTokens = 0;
            if \(contextUsagePercentage !== null && contextUsagePercentage > 0\) \{
                const totalContextTokens = KIRO_CONSTANTS\.TOTAL_CONTEXT_TOKENS;
                // totalUsedTokens 就是通过百分比计算出的总使用量，直接作为 total_tokens
                totalTokens = Math\.round\(totalContextTokens \* contextUsagePercentage / 100\);
                outputTokens = Math\.max\(0, totalTokens - inputTokens\);
                console\.log\(`\[Kiro\] Token calculation from contextUsagePercentage: total=\$\{totalTokens\}, input=\$\{inputTokens\}, output=\$\{outputTokens\}`\);
            \} else \{
                // 回退到原来的计算方式
                outputTokens = this\.countTextTokens\(totalContent\);
                for \(const tc of toolCalls\) \{
                    outputTokens \+= this\.countTextTokens\(JSON\.stringify\(tc\.input \|\| \{\}\)\);
                \}
                totalTokens = inputTokens \+ outputTokens;
            \}'''

new_streaming_pattern = '''            // 6. 发送 message_delta 事件
            // 三层优先级策略：
            // 1. 优先使用 Claude 官方 tokenizer (@anthropic-ai/tokenizer) 精确计算
            // 2. 如果 tokenizer 失败，使用 contextUsagePercentage 计算
            // 3. 如果都没有，使用文本长度估算
            let totalTokens = 0;
            let calculationMethod = 'unknown';

            try {
                // 优先：使用 Claude 官方 tokenizer 精确计算
                outputTokens = this.countTextTokens(totalContent);
                for (const tc of toolCalls) {
                    outputTokens += this.countTextTokens(JSON.stringify(tc.input || {}));
                }
                totalTokens = inputTokens + outputTokens;
                calculationMethod = 'tokenizer';
                console.log(`[Kiro] Token calculation (PRECISE - Claude Official Tokenizer): total=${totalTokens}, input=${inputTokens}, output=${outputTokens}`);
            } catch (tokenizerError) {
                // 回退1：使用 contextUsagePercentage 计算
                console.warn(`[Kiro] Tokenizer failed: ${tokenizerError.message}, falling back to contextUsagePercentage`);

                if (contextUsagePercentage !== null && contextUsagePercentage > 0) {
                    const totalContextTokens = KIRO_CONSTANTS.TOTAL_CONTEXT_TOKENS;
                    totalTokens = Math.round(totalContextTokens * contextUsagePercentage / 100);
                    outputTokens = Math.max(0, totalTokens - inputTokens);
                    calculationMethod = 'contextUsagePercentage';
                    console.log(`[Kiro] Token calculation (FALLBACK - contextUsagePercentage): total=${totalTokens}, input=${inputTokens}, output=${outputTokens}, percentage=${contextUsagePercentage}%`);
                } else {
                    // 回退2：使用文本长度估算（最后兜底）
                    outputTokens = Math.ceil((totalContent || '').length / 4);
                    for (const tc of toolCalls) {
                        outputTokens += Math.ceil(JSON.stringify(tc.input || {}).length / 4);
                    }
                    totalTokens = inputTokens + outputTokens;
                    calculationMethod = 'estimation';
                    console.warn(`[Kiro] Token calculation (ESTIMATION - text length / 4): total=${totalTokens}, input=${inputTokens}, output=${outputTokens}`);
                }
            }'''

if re.search(old_streaming_pattern, content, flags=re.MULTILINE | re.DOTALL):
    content = re.sub(old_streaming_pattern, new_streaming_pattern, content, flags=re.MULTILINE | re.DOTALL)
    modifications_made.append("✓ 流式响应 (generateContentStream)")
else:
    print("⚠ 未找到流式响应的匹配代码块")

# ============================================================
# 修改 2: 非流式响应 - buildClaudeResponse 方法（流式模式）
# ============================================================
old_buildresponse_streaming = r'''            if \(toolCalls && toolCalls\.length > 0\) \{
                toolCalls\.forEach\(\(tc, index\) => \{
                    let inputObject;
                    try \{
                        // Arguments should be a stringified JSON object, need to parse it
                        const args = tc\.function\.arguments;
                        inputObject = typeof args === 'string' \? JSON\.parse\(args\) : args;
                    \} catch \(e\) \{
                        console\.warn\(`\[Kiro\] Invalid JSON for tool call arguments\. Wrapping in raw_arguments\. Error: \$\{e\.message\}`\, tc\.function\.arguments\);
                        // If parsing fails, wrap the raw string in an object as a fallback,
                        // since Claude's `input` field expects an object\.
                        inputObject = \{ "raw_arguments": tc\.function\.arguments \};
                    \}
                    // 2\. content_block_start for each tool_use
                    events\.push\(\{
                        type: "content_block_start",
                        index: index,
                        content_block: \{
                            type: "tool_use",
                            id: tc\.id,
                            name: tc\.function\.name,
                            input: \{\} // input is streamed via input_json_delta
                        \}
                    \}\);

                    // 3\. content_block_delta for each tool_use
                    // Since Kiro is not truly streaming, we send the full arguments as one delta\.
                    events\.push\(\{
                        type: "content_block_delta",
                        index: index,
                        delta: \{
                            type: "input_json_delta",
                            partial_json: JSON\.stringify\(inputObject\)
                        \}
                    \}\);

                    // 4\. content_block_stop for each tool_use
                    events\.push\(\{
                        type: "content_block_stop",
                        index: index
                    \}\);
                    totalOutputTokens \+= this\.countTextTokens\(JSON\.stringify\(inputObject\)\);
                \}\);
                stopReason = "tool_use"; // If there are tool calls, the stop reason is tool_use
            \}'''

new_buildresponse_streaming = '''            if (toolCalls && toolCalls.length > 0) {
                toolCalls.forEach((tc, index) => {
                    let inputObject;
                    try {
                        // Arguments should be a stringified JSON object, need to parse it
                        const args = tc.function.arguments;
                        inputObject = typeof args === 'string' ? JSON.parse(args) : args;
                    } catch (e) {
                        console.warn(`[Kiro] Invalid JSON for tool call arguments. Wrapping in raw_arguments. Error: ${e.message}`, tc.function.arguments);
                        // If parsing fails, wrap the raw string in an object as a fallback,
                        // since Claude's `input` field expects an object.
                        inputObject = { "raw_arguments": tc.function.arguments };
                    }
                    // 2. content_block_start for each tool_use
                    events.push({
                        type: "content_block_start",
                        index: index,
                        content_block: {
                            type: "tool_use",
                            id: tc.id,
                            name: tc.function.name,
                            input: {} // input is streamed via input_json_delta
                        }
                    });

                    // 3. content_block_delta for each tool_use
                    // Since Kiro is not truly streaming, we send the full arguments as one delta.
                    events.push({
                        type: "content_block_delta",
                        index: index,
                        delta: {
                            type: "input_json_delta",
                            partial_json: JSON.stringify(inputObject)
                        }
                    });

                    // 4. content_block_stop for each tool_use
                    events.push({
                        type: "content_block_stop",
                        index: index
                    });
                    // 优先使用 Claude 官方 tokenizer，失败则使用文本长度估算
                    try {
                        totalOutputTokens += this.countTextTokens(JSON.stringify(inputObject));
                    } catch (e) {
                        totalOutputTokens += Math.ceil(JSON.stringify(inputObject).length / 4);
                    }
                });
                stopReason = "tool_use"; // If there are tool calls, the stop reason is tool_use
            }'''

if re.search(old_buildresponse_streaming, content, flags=re.MULTILINE | re.DOTALL):
    content = re.sub(old_buildresponse_streaming, new_buildresponse_streaming, content, flags=re.MULTILINE | re.DOTALL)
    modifications_made.append("✓ 非流式响应 - buildClaudeResponse (流式模式)")
else:
    print("⚠ 未找到 buildClaudeResponse 流式模式的匹配代码块")

# ============================================================
# 修改 3: 非流式响应 - buildClaudeResponse 方法（非流式模式）
# ============================================================
old_buildresponse_nonstreaming = r'''            if \(toolCalls && toolCalls\.length > 0\) \{
                for \(const tc of toolCalls\) \{
                    let inputObject;
                    try \{
                        // Arguments should be a stringified JSON object, need to parse it
                        const args = tc\.function\.arguments;
                        inputObject = typeof args === 'string' \? JSON\.parse\(args\) : args;
                    \} catch \(e\) \{
                        console\.warn\(`\[Kiro\] Invalid JSON for tool call arguments\. Wrapping in raw_arguments\. Error: \$\{e\.message\}`\, tc\.function\.arguments\);
                        // If parsing fails, wrap the raw string in an object as a fallback,
                        // since Claude's `input` field expects an object\.
                        inputObject = \{ "raw_arguments": tc\.function\.arguments \};
                    \}
                    contentArray\.push\(\{
                        type: "tool_use",
                        id: tc\.id,
                        name: tc\.function\.name,
                        input: inputObject
                    \}\);
                    outputTokens \+= this\.countTextTokens\(tc\.function\.arguments\);
                \}
                stopReason = "tool_use"; // Set stop_reason to "tool_use" when toolCalls exist
            \} else if \(content\) \{
                contentArray\.push\(\{
                    type: "text",
                    text: content
                \}\);
                outputTokens \+= this\.countTextTokens\(content\);
            \}'''

new_buildresponse_nonstreaming = '''            if (toolCalls && toolCalls.length > 0) {
                for (const tc of toolCalls) {
                    let inputObject;
                    try {
                        // Arguments should be a stringified JSON object, need to parse it
                        const args = tc.function.arguments;
                        inputObject = typeof args === 'string' ? JSON.parse(args) : args;
                    } catch (e) {
                        console.warn(`[Kiro] Invalid JSON for tool call arguments. Wrapping in raw_arguments. Error: ${e.message}`, tc.function.arguments);
                        // If parsing fails, wrap the raw string in an object as a fallback,
                        // since Claude's `input` field expects an object.
                        inputObject = { "raw_arguments": tc.function.arguments };
                    }
                    contentArray.push({
                        type: "tool_use",
                        id: tc.id,
                        name: tc.function.name,
                        input: inputObject
                    });
                    // 优先使用 Claude 官方 tokenizer (@anthropic-ai/tokenizer)，失败则使用文本长度估算
                    try {
                        outputTokens += this.countTextTokens(JSON.stringify(inputObject));
                    } catch (e) {
                        console.warn(`[Kiro] Tokenizer failed for tool call, using estimation: ${e.message}`);
                        outputTokens += Math.ceil(JSON.stringify(inputObject).length / 4);
                    }
                }
                stopReason = "tool_use"; // Set stop_reason to "tool_use" when toolCalls exist
            } else if (content) {
                contentArray.push({
                    type: "text",
                    text: content
                });
                // 优先使用 Claude 官方 tokenizer (@anthropic-ai/tokenizer)，失败则使用文本长度估算
                try {
                    outputTokens += this.countTextTokens(content);
                } catch (e) {
                    console.warn(`[Kiro] Tokenizer failed for content, using estimation: ${e.message}`);
                    outputTokens += Math.ceil((content || '').length / 4);
                }
            }'''

if re.search(old_buildresponse_nonstreaming, content, flags=re.MULTILINE | re.DOTALL):
    content = re.sub(old_buildresponse_nonstreaming, new_buildresponse_nonstreaming, content, flags=re.MULTILINE | re.DOTALL)
    modifications_made.append("✓ 非流式响应 - buildClaudeResponse (非流式模式)")
else:
    print("⚠ 未找到 buildClaudeResponse 非流式模式的匹配代码块")

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

    # 执行修复
    fix_token_calculation "$file"

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
    并将 outtokens 的计算逻辑修改为三层优先级策略。

    三层优先级策略：
    1. 优先：使用 Claude 官方 tokenizer (@anthropic-ai/tokenizer) 精确计算
    2. 回退1：如果 tokenizer 失败，使用 contextUsagePercentage 计算
    3. 回退2：如果都没有，使用文本长度估算（length / 4）

    修改位置：
    - 流式响应 (generateContentStream): 完整的三层策略
    - 非流式响应 (buildClaudeResponse): tokenizer + 文本估算

    所有修改前的文件都会自动备份（.backup.时间戳）。

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
