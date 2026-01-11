#!/bin/sh

set -e

echo "=========================================="
echo "Kiro Token 计算精确化改进脚本"
echo "=========================================="

# 容器名称
CONTAINER_NAME="aiclient2api"
FILE_PATH="/app/src/providers/claude/claude-kiro. js"

# 1. 检查容器是否运行
echo "✅ 步骤 1: 检查容器状态..."
if ! docker ps | grep -q $CONTAINER_NAME; then
    echo "❌ 容器 $CONTAINER_NAME 未运行"
    exit 1
fi
echo "✅ 容器 $CONTAINER_NAME 正在运行"

# 2. 备份原文件
echo ""
echo "✅ 步骤 2: 备份原文件..."
BACKUP_TIME=$(date +%s)
docker exec $CONTAINER_NAME sh -c "cp $FILE_PATH ${FILE_PATH}.bak. ${BACKUP_TIME}"
echo "✅ 备份完成:  ${FILE_PATH}.bak.${BACKUP_TIME}"

# 3. 创建改进代码的临时文件
echo ""
echo "✅ 步骤 3: 创建改进代码..."

cat > /tmp/replace_kiro.js << 'NODEJS_SCRIPT'
const fs = require('fs');
const path = process.argv[2];

let content = fs.readFileSync(path, 'utf8');

// 使用更灵活的正则表达式匹配
const altPattern = /if \(contextUsagePercentage !== null && contextUsagePercentage > 0\) \{[\s\S]*?\} else \{[\s\S]*?  totalTokens = inputTokens \+ outputTokens;\n            \}/;

if (altPattern.test(content)) {
    const newCode = `outputTokens = this.countTextTokens(totalContent);
            for (const tc of toolCalls) {
                outputTokens += this.countTextTokens(JSON.stringify(tc. input || {}));
            }
            const totalTokens = inputTokens + outputTokens;
            
            console.log(\`[Kiro] ACCURATE Token calculation:  total=\${totalTokens}, input=\${inputTokens}, output=\${outputTokens}\`);`;
    
    content = content.replace(altPattern, newCode);
    fs.writeFileSync(path, content, 'utf8');
    console.log('✅ 文件替换成功！');
    process.exit(0);
} else {
    console.error('❌ 无法找到匹配的代码段，正在尝试备选方案...');
    
    // 备选方案：更宽松的匹配
    const loosePattern = /let totalTokens = 0;[\s\S]*?yield \{\s*type: "message_delta",[\s\S]*? usage: \{ input_tokens: inputTokens, output_tokens: outputTokens, total_tokens: totalTokens \}\s*\};/;
    
    if (loosePattern.test(content)) {
        const newCode2 = `// ✅ 改进：直接使用 Claude tokenizer 精确计算，不依赖 contextUsagePercentage
            outputTokens = this.countTextTokens(totalContent);
            for (const tc of toolCalls) {
                outputTokens += this.countTextTokens(JSON. stringify(tc.input || {}));
            }
            const totalTokens = inputTokens + outputTokens;
            
            console. log(\`[Kiro] ACCURATE Token calculation: total=\${totalTokens}, input=\${inputTokens}, output=\${outputTokens}\`);
            
            yield {
                type: "message_delta",
                delta: { stop_reason: toolCalls.length > 0 ? "tool_use" : "end_turn" },
                usage: { input_tokens: inputTokens, output_tokens: outputTokens, total_tokens: totalTokens }
            };`;
        
        content = content. replace(loosePattern, newCode2);
        fs.writeFileSync(path, content, 'utf8');
        console.log('✅ 文件替换成功（备选方案）！');
        process.exit(0);
    } else {
        console.error('❌ 无法找到任何匹配的代码段');
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

# 4. 验证改动
echo ""
echo "✅ 步骤 4: 验证改动..."
docker exec $CONTAINER_NAME grep -A 8 "ACCURATE Token calculation" $FILE_PATH || echo "⚠️  未找到新代码，可能文件格式不同"

# 5. 检查语法
echo ""
echo "✅ 步骤 5: 检查 Node.js 语法..."
docker exec $CONTAINER_NAME node -c $FILE_PATH
if [ $? -eq 0 ]; then
    echo "✅ 语法检查通过"
else
    echo "❌ 语法检查失败，准备恢复..."
    docker exec $CONTAINER_NAME sh -c "cp ${FILE_PATH}. bak.${BACKUP_TIME} $FILE_PATH"
    exit 1
fi

# 6. 重启容器
echo ""
echo "✅ 步骤 6: 重启容器..."
docker restart $CONTAINER_NAME
echo "⏳ 等待容器启动..."
sleep 10

# 7. 验证容器
echo ""
echo "✅ 步骤 7: 验证容器状态..."
if docker ps | grep -q $CONTAINER_NAME; then
    echo "✅ 容器已正常启动"
    sleep 3
    echo ""
    echo "📋 容器最近日志："
    docker logs --tail 30 $CONTAINER_NAME | grep -E "ACCURATE Token calculation|Kiro|Error" || echo "⚠️  未找到相关日志"
else
    echo "❌ 容器启动失败"
    echo "准备恢复备份..."
    docker exec $CONTAINER_NAME sh -c "cp ${FILE_PATH}.bak.${BACKUP_TIME} $FILE_PATH"
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
echo "📂 备份文件："
docker exec $CONTAINER_NAME sh -c "ls -lh ${FILE_PATH}.bak. * 2>/dev/null || echo '未找���备份文件'"
echo ""
echo "🔄 要恢复备份，执行："
echo "  docker exec $CONTAINER_NAME sh -c 'cp ${FILE_PATH}.bak.${BACKUP_TIME} $FILE_PATH'"
echo "  docker restart $CONTAINER_NAME"
echo ""
