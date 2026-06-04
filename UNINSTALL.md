# 卸载 & 清理指南

当 Codex 官方开放额度查询后，这个工具就完成了使命。以下是完整清理步骤。

## 清理 Codex 钩子

```bash
# 删除 ~/.codex/hooks.json 中的 codex-credits 相关条目
python3 -c "
import json
hooks_file = '/Users/$(whoami)/.codex/hooks.json'
with open(hooks_file) as f:
    config = json.load(f)
h = config.get('hooks', {})
for event in ['PostToolUse', 'Stop']:
    h[event] = [e for e in h.get(event, []) if 'codex-credits' not in json.dumps(e)]
with open(hooks_file, 'w') as f:
    json.dump(config, f, indent=2)
print('✅ 钩子已清理')
"
```

## 卸载菜单栏

```bash
# 移除 SwiftBar 插件
rm ~/Library/SwiftBar/plugins/codex.10s.sh

# 清理 SwiftBar 配置
defaults delete com.ameba.SwiftBar PluginDirectory 2>/dev/null || true
```

## 删除项目

```bash
# 移除别名
sed -i '' '/alias codex=/d' ~/.zshrc

# 删除配置
rm ~/.codex-credits.json

# 删除整个项目目录
rm -rf ~/"VS Code/Code/codex-credits"
```

## 一键卸载

```bash
curl -sL https://raw.githubusercontent.com/JalenLyu/codex-credits/main/uninstall.sh | bash
```
