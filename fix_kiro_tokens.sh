#!/bin/bash

set -e

echo "=========================================="
echo "Kiro Token 计算精确化改进脚本"
echo "=========================================="

# 容器名称
CONTAINER_NAME="aiclient2api"
FILE_PATH="/app/src/providers/claude/claude-kiro.js"

# 1. 检查容器是否运行
echo "✅ 步骤 1: 检查容器状态..."
if !  docker ps | grep -q $CONTAINER_NAME; then
    echo "❌ 容器 $CONTAINER_NAME 未运行"
    exit 1
fi
echo "✅ 容器 $CONTAINER_NAME 正在运行"

# 2. 备份原文件
echo ""
echo "✅ 步骤 2: 备份原文件..."
docker exec $CONTAINER_NAME bash -c "cp $FILE_PATH ${FILE_PATH}.bak. $(date +%s)"
echo "✅ 备份完成:  ${FILE_PATH}.bak.*"

# 3. 创建改进代码的临时文件
echo ""
echo "✅ 步骤 3: 创建改进代码..."
cat > /tmp/kiro_fix.txt << 'REPLACEMENT'
            // 6. 发送 message_delta 事件
            // ✅ 改进：直接使用 Claude tokenizer 精确计算，不依赖 contextUsagePercentage
            outputTokens = this.countTextTokens(totalContent);
            for (const tc of toolCalls) {
                outputTokens += this.countTextTokens(JSON.stringify(tc.input || {}));
            }
            const totalTokens = inputTokens + outputTokens;
            
            console.log(`[Kiro] ACCURATE Token calculation: total=${totalTokens}, input=${inputTokens}, output=${outputTokens}`);
            
            yield {
                type: "message_delta",
                delta:  { stop_reason: toolCalls.length > 0 ? "tool_use" : "end_turn" },
                usage: { input_tokens: inputTokens, output_tokens: outputTokens, total_tokens: totalTokens }
            };
REPLACEMENT

echo "✅ 改进代码已准备"

# 4. 执行 Node.js 脚本进行替换
echo ""
echo "✅ 步骤 4: 执行文件替换..."

cat > /tmp/replace_kiro.js << 'NODEJS_SCRIPT'
const fs = require('fs');
const path = process.argv[2];

// 读取文件
let content = fs.readFileSync(path, 'utf8');

// 原始代码的精确匹配（包含所有空格和换行）
const oldPattern = /            \/\/ 6\. 发送 message_delta 事件\n            \/\/ 如果有 contextUsagePercentage，使用它来计算 token\n            \/\/ 总上下文 200k tokens，通过百分比计算总使用量，再减去输入 token 得到输出 token\n            let totalTokens = 0;\n            if \(contextUsagePercentage !== null && contextUsagePercentage > 0\) \{\n                const totalContextTokens = KIRO_CONSTANTS\. TOTAL_CONTEXT_TOKENS;\n                \/\/ totalUsedTokens 就是通过百分比计算出的总使用量，直接作为 total_tokens\n                totalTokens = Math\.round\(totalContextTokens \* contextUsagePercentage \/ 100\);\n                outputTokens = Math\.max\(0, totalTokens - inputTokens\);\n                console\.log\(`\[Kiro\] Token calculation from contextUsagePercentage: total=\$\{totalTokens\}, input=\$\{inputTokens\}, output=\$\{outputTokens\}`\);\n            \} else \{\n                \/\/ 回退到原来的计算方式\n                outputTokens = this\.countTextTokens\(totalContent\);\n                for \(const tc of toolCalls\) \{\n                    outputTokens \+= this\.countTextTokens\(JSON\.stringify\(tc\.input \|\| \{\}\)\);\n                \}\n                totalTokens = inputTokens \+ outputTokens;\n            \}\n            \n            yield \{\n                type: "message_delta",\n                delta: \{ stop_reason: toolCalls\. length > 0 \? "tool_use" : "end_turn" \},\n                usage: \{ input_tokens: inputTokens, output_tokens: outputTokens, total_tokens: totalTokens \}\n            \};/;

const newCode = `            // 6. 发送 message_delta 事件
            // ✅ 改进：直接使用 Claude tokenizer 精确计算，不依赖 contextUsagePercentage
            outputTokens = this.countTextTokens(totalContent);
            for (const tc of toolCalls) {
                outputTokens += this.countTextTokens(JSON.stringify(tc.input || {}));
            }
            const totalTokens = inputTokens + outputTokens;
            
            console.log(\`[Kiro] ACCURATE Token calculation: total=\${totalTokens}, input=\${inputTokens}, output=\${outputTokens}\`);
            
            yield {
                type: "message_delta",
                delta:  { stop_reason: toolCalls.length > 0 ? "tool_use" : "end_turn" },
                usage: { input_tokens: inputTokens, output_tokens: outputTokens, total_tokens: totalTokens }
            };`;

// 尝试替换
if (oldPattern.test(content)) {
    content = content.replace(oldPattern, newCode);
    fs.writeFileSync(path, content, 'utf8');
    console.log('✅ 文件替换成功！');
    process.exit(0);
} else {
    // 备选方案：使用更灵活的正则
    const altPattern = /if \(contextUsagePercentage !== null && contextUsagePercentage > 0\) \{[\s\S]*?\} else \{[\s\S]*? totalTokens = inputTokens \+ outputTokens;\n            \}/;
    if (altPattern.test(content)) {
        content = content.replace(altPattern, `outputTokens = this.countTextTokens(totalContent);
            for (const tc of toolCalls) {
                outputTokens += this.countTextTokens(JSON. stringify(tc.input || {}));
            }
            const totalTokens = inputTokens + outputTokens;
            
            console. log(\`[Kiro] ACCURATE Token calculation: total=\${totalTokens}, input=\${inputTokens}, output=\${outputTokens}\`);`);
        fs.writeFileSync(path, content, 'utf8');
        console.log('✅ 文件替换成功（备选方案）！');
        process.exit(0);
    } else {
        console.error('❌ 无法找到匹配的代码段，请检查文件内容');
        process.exit(1);
    }
}
NODEJS_SCRIPT

docker cp /tmp/replace_kiro. js $CONTAINER_NAME:/tmp/replace_kiro.js
docker exec $CONTAINER_NAME node /tmp/replace_kiro. js $FILE_PATH

if [ $? -eq 0 ]; then
    echo "✅ 文件替换成功"
else
    echo "❌ 文件替换失败"
    exit 1
fi

# 5. 验证改动
echo ""
echo "✅ 步骤 5: 验证改动..."
docker exec $CONTAINER_NAME grep -A 8 "ACCURATE Token calculation" $FILE_PATH

# 6. 检查语法错误
echo ""
echo "✅ 步骤 6: 检查 Node.js 语法..."
docker exec $CONTAINER_NAME node -c $FILE_PATH
if [ $? -eq 0 ]; then
    echo "✅ 语法检查通过"
else
    echo "❌ 语法检查失败，请恢复备份"
    exit 1
fi

# 7. 重启容器
echo ""
echo "✅ 步骤 7: 重启容器..."
docker restart $CONTAINER_NAME
echo "✅ 等待容器启动..."
sleep 5

# 8. 验证容器状态
echo ""
echo "✅ 步骤 8: 验证容器状态..."
if docker ps | grep -q $CONTAINER_NAME; then
    echo "✅ 容器已正常启动"
else
    echo "❌ 容器启动失败"
    exit 1
fi

# 9. 查看日志验证改动
echo ""
echo "✅ 步骤 9: 查看容器日志（最近 20 行）..."
docker logs --tail 20 $CONTAINER_NAME

echo ""
echo "=========================================="
echo "✅ 所有步骤完成！"
echo "=========================================="
echo ""
echo "📝 改动摘要："
echo "  • 删除了基于 contextUsagePercentage 的错误 token 计算"
echo "  • 改用 Claude 官方 tokenizer 精确计算 output tokens"
echo "  • 简化了逻辑，提高了准确性"
echo ""
echo "📂 备份文件位置："
docker exec $CONTAINER_NAME bash -c "ls -lh /app/src/providers/claude/claude-kiro.js*" | grep -E "\.bak\.|claude-kiro\. js"
echo ""
echo "🔄 要恢复备份，执行："
echo "docker exec $CONTAINER_NAME bash -c 'cp /app/src/providers/claude/claude-kiro.js. bak. * /app/src/providers/claude/claude-kiro.js'"
echo "docker restart $CONTAINER_NAME"
echo ""
