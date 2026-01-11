#!/bin/sh

set -e

echo "=========================================="
echo "Kiro Token 计算精确化改进脚本"
echo "=========================================="

# 容器名称
CONTAINER_NAME="aiclient2api"
FILE_PATH="/app/src/providers/claude/claude-kiro. js"

# 1. 检查容器是否运行
echo "✅ 步骤 1: 检查容��状态..."
if !  docker ps | grep -q $CONTAINER_NAME; then
    echo "❌ 容器 $CONTAINER_NAME 未运行"
    exit 1
fi
echo "✅ 容器 $CONTAINER_NAME 正在运行"

# 2. 备份原文件
echo ""
echo "✅ 步骤 2: 备份原文件..."
BACKUP_TIME=$(date +%s)
docker exec $CONTAINER_NAME cp $FILE_PATH ${FILE_PATH}.bak.${BACKUP_TIME}
echo "✅ 备份完成:  ${FILE_PATH}.bak.${BACKUP_TIME}"

# 3. 创建改进代码脚本
echo ""
echo "✅ 步骤 3: 创建改进代码..."

cat > /tmp/replace_kiro.js << 'NODEJS_SCRIPT'
const fs = require('fs');
const path = process.argv[2];

console.log('📖 开始读取文件:  ' + path);
let content = fs.readFileSync(path, 'utf8');

console.log('🔍 寻找匹配的代码段...');

// 方案 1: 精确匹配
const pattern1 = /if \(contextUsagePercentage !== null && contextUsagePercentage > 0\) \{[\s\S]*?\} else \{[\s\S]*? totalTokens = inputTokens \+ outputTokens;\n            \}/;

// 方案 2: 宽松匹配
const pattern2 = /let totalTokens = 0;[\s\S]*?yield \{\s*type:  "message_delta",[\s\S]*? usage: \{ input_tokens: inputTokens, output_tokens: outputTokens, total_tokens: totalTokens \}\s*\};/;

// 方案 3: 超宽松匹配
const pattern3 = /contextUsagePercentage !== null[\s\S]*?totalTokens = inputTokens \+ outputTokens;/;

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

if (pattern1.test(content)) {
    console.log('✅ 使用方案 1 (精确匹配)');
    content = content.replace(pattern1, newCode);
    replaced = true;
} else if (pattern2.test(content)) {
    console.log('✅ 使用方案 2 (宽松匹配)');
    content = content.replace(pattern2, newCode);
    replaced = true;
} else if (pattern3.test(content)) {
    console.log('✅ 使用方案 3 (超宽松匹配)');
    content = content.replace(pattern3, newCode);
    replaced = true;
} else {
    console.error('❌ 无法找到任何匹配的代码段');
    console.error('');
    console.error('检查文件中是否包含以下关键字: ');
    console.error('  • contextUsagePercentage');
    console.error('  • message_delta');
    console.error('  • totalTokens');
    
    // 输出前后文以帮助调试
    const idx = content.indexOf('message_delta');
    if (idx !== -1) {
        console.error('');
        console.error('找到 message_delta，上下文: ');
        console.error(content.substring(Math.max(0, idx - 200), idx + 200));
    }
    
    process.exit(1);
}

if (replaced) {
    fs.writeFileSync(path, content, 'utf8');
    console.log('✅ 文件替换成功！');
    process.exit(0);
}
NODEJS_SCRIPT

echo "📋 开始替换文件..."
docker cp /tmp/replace_kiro. js $CONTAINER_NAME:/tmp/replace_kiro.js
docker exec $CONTAINER_NAME node /tmp/replace_kiro. js $FILE_PATH

if [ $? -ne 0 ]; then
    echo "❌ 文件替换失败"
    echo "⏮️  正在恢复备份..."
    docker exec $CONTAINER_NAME cp ${FILE_PATH}.bak.${BACKUP_TIME} $FILE_PATH
    exit 1
fi

# 4. 验证改动
echo ""
echo "✅ 步骤 4: 验证改动..."
if docker exec $CONTAINER_NAME grep -q "ACCURATE Token calculation" $FILE_PATH; then
    echo "✅ 新代码已写入文件"
    docker exec $CONTAINER_NAME grep -A 5 "ACCURATE Token calculation" $FILE_PATH
else
    echo "⚠️  警告：未找到新代码，但替换可能已执行"
fi

# 5. 检查语法
echo ""
echo "✅ 步骤 5: 检查 Node.js 语法..."
if docker exec $CONTAINER_NAME node -c $FILE_PATH; then
    echo "✅ 语法检查通过"
else
    echo "❌ 语法检查失败，准备恢复..."
    docker exec $CONTAINER_NAME cp ${FILE_PATH}.bak. ${BACKUP_TIME} $FILE_PATH
    exit 1
fi

# 6. 重启容器
echo ""
echo "✅ 步骤 6: 重启容器..."
docker restart $CONTAINER_NAME
echo "⏳ 等待容器启动（10 秒）..."
sleep 10

# 7. 验证容器
echo ""
echo "✅ 步骤 7: 验证容器状态..."
if docker ps | grep -q $CONTAINER_NAME; then
    echo "✅ 容器已正常启动"
    echo ""
    echo "📋 容器最近日志（最后 20 行）:"
    docker logs --tail 20 $CONTAINER_NAME
else
    echo "❌ 容器启动失败"
    echo "⏮️  准备恢复备份..."
    docker exec $CONTAINER_NAME cp ${FILE_PATH}.bak. ${BACKUP_TIME} $FILE_PATH
    docker restart $CONTAINER_NAME
    exit 1
fi

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
echo "📂 备份文件:  ${FILE_PATH}.bak. ${BACKUP_TIME}"
echo ""
echo "🔄 要恢复备份，执行:"
echo "   docker exec $CONTAINER_NAME cp ${FILE_PATH}.bak. ${BACKUP_TIME} $FILE_PATH"
echo "   docker restart $CONTAINER_NAME"
echo ""
