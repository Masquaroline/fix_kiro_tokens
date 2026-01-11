#!/bin/sh

set -e

echo "=========================================="
echo "Kiro Token 计算精确化改进脚本"
echo "=========================================="

CONTAINER_NAME="aiclient2api"
FILE_PATH="/app/src/providers/claude/claude-kiro. js"

# 1. 检查容器是否运行
echo "✅ 步骤 1: 检查容器状态..."
if !  docker ps | grep -q $CONTAINER_NAME; then
    echo "❌ 容器 $CONTAINER_NAME 未运行"
    exit 1
fi
echo "✅ 容器 $CONTAINER_NAME 正在运行"

# 2. 获取容器的 shell
echo ""
echo "✅ 步骤 2: 检测容器 shell..."
SHELL_TYPE=$(docker exec $CONTAINER_NAME which sh 2>/dev/null || echo "/bin/sh")
echo "✅ 使用 shell: $SHELL_TYPE"

# 3. 备份原文件
echo ""
echo "✅ 步骤 3: 备份原文件..."
BACKUP_TIME=$(date +%s)
docker run --rm --volumes-from $CONTAINER_NAME -v /tmp:/tmp alpine cp $FILE_PATH ${FILE_PATH}.bak. ${BACKUP_TIME} 2>/dev/null || \
docker cp $CONTAINER_NAME: $FILE_PATH /tmp/claude-kiro.js. bak. ${BACKUP_TIME}
echo "✅ 备份完成"

# 4. 创建改进代码脚本
echo ""
echo "✅ 步骤 4: 创建改进代码..."

cat > /tmp/replace_kiro.js << 'NODEJS_SCRIPT'
const fs = require('fs');
const path = process.argv[2];

console.log('📖 开始读取文件:  ' + path);
let content = fs.readFileSync(path, 'utf8');
console.log('✅ 文件大小: ' + content.length + ' 字节');

console.log('🔍 寻找匹配的代码段...');

// 最宽松的匹配：只匹配关键的代码块结构
const patterns = [
    {
        name: '方案 1 (精确)',
        regex: /if \(contextUsagePercentage !== null && contextUsagePercentage > 0\) \{[\s\S]*?\} else \{[\s\S]*? totalTokens = inputTokens \+ outputTokens;\n            \}/
    },
    {
        name: '方案 2 (宽松)',
        regex: /let totalTokens = 0;[\s\S]*? yield \{\s*type:  "message_delta",[\s\S]*? usage: \{ input_tokens: inputTokens, output_tokens: outputTokens, total_tokens: totalTokens \}\s*\};/
    },
    {
        name: '方案 3 (超宽松)',
        regex: /if \(contextUsagePercentage[\s\S]*? totalTokens = inputTokens \+ outputTokens;[\s\S]*? yield \{[\s\S]*?type:  "message_delta"/
    }
];

const newCode = `outputTokens = this.countTextTokens(totalContent);
            for (const tc of toolCalls) {
                outputTokens += this.countTextTokens(JSON.stringify(tc. input || {}));
            }
            const totalTokens = inputTokens + outputTokens;
            
            console.log(\`[Kiro] ACCURATE Token calculation:  total=\${totalTokens}, input=\${inputTokens}, output=\${outputTokens}\`);
            
            yield {
                type: "message_delta",
                delta: { stop_reason: toolCalls.length > 0 ? "tool_use" : "end_turn" },
                usage: { input_tokens: inputTokens, output_tokens: outputTokens, total_tokens: totalTokens }
            };`;

let replaced = false;
for (const pattern of patterns) {
    if (pattern.regex.test(content)) {
        console.log('✅ ' + pattern.name);
        content = content.replace(pattern.regex, newCode);
        replaced = true;
        break;
    }
}

if (!replaced) {
    console.error('❌ 无法找到任何匹配的代码段');
    // 列出文件中的关键字出现次数
    console.error('');
    console.error('文件内容检查:');
    console.error('  contextUsagePercentage: ' + (content.match(/contextUsagePercentage/g) || []).length + ' 次');
    console.error('  message_delta:  ' + (content.match(/message_delta/g) || []).length + ' 次');
    console.error('  totalTokens: ' + (content. match(/totalTokens/g) || []).length + ' 次');
    process.exit(1);
}

fs.writeFileSync(path, content, 'utf8');
console.log('✅ 文件替换成功! ');
process.exit(0);
NODEJS_SCRIPT

echo "📋 开始替换文件..."
docker cp /tmp/replace_kiro. js $CONTAINER_NAME:/tmp/replace_kiro.js
docker exec $CONTAINER_NAME node /tmp/replace_kiro. js $FILE_PATH

if [ $? -ne 0 ]; then
    echo "❌ 文件替换失败"
    exit 1
fi

# 5. 验证改动
echo ""
echo "✅ 步骤 5: 验证改动..."
docker cp $CONTAINER_NAME: $FILE_PATH /tmp/claude-kiro.js.new
if grep -q "ACCURATE Token calculation" /tmp/claude-kiro. js.new; then
    echo "✅ 新代码已成功写入"
    grep -A 5 "ACCURATE Token calculation" /tmp/claude-kiro.js.new
else
    echo "⚠️  警告：未找到新代码"
fi

# 6. 检查语法
echo ""
echo "✅ 步骤 6: 检查 Node.js 语法..."
if docker exec $CONTAINER_NAME node -c $FILE_PATH; then
    echo "✅ 语法检查通过"
else
    echo "❌ 语法检查失败"
    echo "⏮️  正在恢复备份..."
    docker cp /tmp/claude-kiro.js.bak.${BACKUP_TIME} $CONTAINER_NAME: $FILE_PATH
    docker restart $CONTAINER_NAME
    exit 1
fi

# 7. 重启容器
echo ""
echo "✅ 步骤 7: 重启容器..."
docker restart $CONTAINER_NAME
echo "⏳ 等待容器启动（15 秒）..."
sleep 15

# 8. 验证容器
echo ""
echo "✅ 步骤 8: 验证容器状态..."
if docker ps | grep -q $CONTAINER_NAME; then
    echo "✅ 容器已正常启动"
    echo ""
    echo "📋 容器日志（最后 30 行）:"
    docker logs --tail 30 $CONTAINER_NAME | tail -30
else
    echo "❌ 容器启动失败"
    exit 1
fi

echo ""
echo "=========================================="
echo "✅ 改进完成！"
echo "=========================================="
echo ""
echo "📝 改动摘要:"
echo "  ✓ 删除基于 contextUsagePercentage 的错误计算"
echo "  ✓ 使用 Claude tokenizer 精确计算 output tokens"
echo "  ✓ 改进日志输出"
echo ""
echo "📂 备份文件:  /tmp/claude-kiro.js.bak.  ${BACKUP_TIME}"
echo ""
echo "🧪 测试命令:"
echo "curl -s -X POST 'https://q.us-east-1.amazonaws.com/generateAssistantResponse' \\"
echo "  -H 'Authorization: Bearer YOUR_TOKEN' \\"
echo "  -H 'Content-Type: application/json' \\"
echo "  -d '{\"conversationState\": {\"chatTriggerType\": \"MANUAL\",\"conversationId\":\"'\" $(uuidgen) \"'\",\"currentMessage\": {\"userInputMessage\": {\"content\": \"你好\",\"modelId\":\"claude-opus-4.5\",\"origin\":\"AI_EDITOR\"}},\"history\": []}}'"
echo ""
