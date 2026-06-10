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

如果菜单栏没有显示：

```bash
brew install --cask swiftbar
open -a SwiftBar
bash scripts/codex-menu-bar.sh   # 手动预览 SwiftBar 输出
```

然后在 SwiftBar 菜单里点 `Refresh All`；插件路径为 `~/Library/SwiftBar/plugins/codex.10s.sh`。

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

## 快速参考

```bash
codex                    # 本周花费
codex --weekly           # 逐日明细
codex --auto-detect      # 探测计费起点
codex --calibrate-start  # 校准首次使用/重置时间
codex --calibrate-rate   # 校准 token 单价
codex --calibrate        # 完整交互式校准
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
  "weekly_budget_dollars": 0,
  "weekly_credits": 1875,
  "tokens_per_credit": 3981,
  "cents_per_credit": 4,
  "output_token_weight": 0,
  "cached_token_weight": 0,
  "reset_weekday": "Wednesday",
  "reset_hour": 15,
  "reset_minute": 16
}
```

## 给 Coding Agent

```bash
# 校准首次使用/重置时间
codex --calibrate-start

# 校准单价（例如当前窗口实际消耗 $75）
codex --calibrate-rate 75

# 设预算（用于自定义百分比阈值）
codex --set-budget 87
```

## 局限性

- **企业定价不透明**：基于 `$75 ≈ 1,875 credits` 反推，不是 API 公开价
- **无法识别额度变更**：申请更高额度后需手动改 `weekly_budget_dollars`
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
