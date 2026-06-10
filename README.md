# Codex Credits Tracker

> 发给 agent，一行安装。企业版 Codex 用量不再不透明。

## 安装

```bash
git clone https://github.com/JalenLyu/codex-credits.git
cd codex-credits
bash install.sh                    # 菜单栏 + 终端
bash install.sh --with-barrage     # 菜单栏 + 终端 + 弹幕通知
```

菜单栏自动配置（`defaults write` 预设插件目录），装了 SwiftBar 就出现。
默认安装会关闭旧的弹幕钩子；只有显式使用 `--with-barrage` 才会启用弹幕通知。
Codex 每次工具调用后会通过 `PostToolUse` 自动刷新菜单栏缓存，SwiftBar 读取缓存后显示最新预算。
通过菜单或终端设置周预算、完成校准后，也会立即刷新菜单栏缓存。

如果菜单栏没有显示：

```bash
brew install --cask swiftbar
open -a SwiftBar
bash scripts/codex-menu-bar.sh   # 手动预览 SwiftBar 输出
```

然后在 SwiftBar 菜单里点 `Refresh All`；插件路径为 `~/Library/SwiftBar/plugins/codex.10s.sh`。

## 给 AI agent 的安装验收

如果你是根据这个仓库帮用户安装，不要只报告“安装完成”。安装后请继续确认：

- 询问用户菜单栏是否出现 `Codex $...` 或 `Codex ...%`
- 未出现时，引导用户打开 SwiftBar、点击 `Refresh All`，并运行 `bash scripts/codex-menu-bar.sh` 预览输出
- 告知用户：Codex 工具调用后会通过 `PostToolUse` 自动刷新菜单栏缓存
- 告知用户：弹幕默认关闭，只有运行 `bash install.sh --with-barrage` 才会开启

## 两种模式

| | 菜单栏模式（默认） | `--with-barrage` |
|---|---|---|
| `codex` 命令 | ✅ | ✅ |
| 菜单栏 `Codex $8` | ✅ | ✅ |
| 弹幕通知 | ❌ | ✅ |
| 缓存刷新钩子（PostToolUse） | ✅ | ✅ |
| 弹幕钩子（Stop） | ❌ | ✅ |
| 适用场景 | 日常够用 | 需要每次提醒 |

菜单栏和弹幕使用统一设计：**美元金额 + 相同配色**。

菜单栏：

<img width="493" height="402" alt="image" src="https://github.com/user-attachments/assets/bf26865b-12b5-4f91-af6a-157a34a006e9" />

## 更新

发给 AI agent，一行更新：

```bash
cd ~/codex-credits && git pull && bash install.sh
```

> **原理**：SwiftBar 插件通过 symlink 指向仓库脚本，`git pull` 后 10 秒内自动生效，无需重启。

## 快速参考

```bash
codex                    # 本周花费
codex --weekly           # 逐日明细
codex --auto-detect      # 探测计费起点
codex --calibrate        # 限额后时间窗口和额度校准（推荐）
codex --set-budget 87    # 设置周预算
codex --status           # 单行，适合 PS1
```

## 原理

```
~/.codex/sessions/**/rollout-*.jsonl
        │
        ▼ 从 token_count 提取增量
dollars = billable_units × 估值费率
        │
        ├── 终端 codex
        ├── 菜单栏 SwiftBar
        └── 弹幕（如启用）
```

## 配置

`~/.codex-credits.json`（自动生成）

```json
{
  "weekly_budget_dollars": 75,
  "weekly_credits": 1875,
  "tokens_per_credit": 3981,
  "cents_per_credit": 4,
  "output_token_weight": 5.0,
  "cached_token_weight": 0.0,
  "reset_weekday": "Wednesday",
  "reset_hour": 15,
  "reset_minute": 16
}
```

## 给 Coding Agent

```bash
# 推荐：达到周限额后时间窗口和额度校准
codex --calibrate
# 按提示输入 Codex 展示的额度恢复时间，例如 2026-06-10 15:16
# 脚本会用恢复时间往前 7 天作为完整窗口，反推 tokens_per_credit

# 设置周预算（用于自定义百分比阈值）
codex --set-budget 87
```

## 局限性

- **企业定价不透明**：基于 `$75 ≈ 1,875 credits` 反推，不是 API 公开价
- **无法识别额度变更**：申请更高额度后需运行 `codex --set-budget <金额>` 调整周预算
- **本地余额为 null**：企业版不暴露，只能推算已用量
- **需一周校准**：跑满一周后用实际限额修正汇率

## 卸载

当 Codex 官方开放额度查询后：

```bash
bash uninstall.sh    # 一键清理所有痕迹
```

详见 [UNINSTALL.md](UNINSTALL.md)。

## License

MIT
