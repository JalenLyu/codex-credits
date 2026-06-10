# 架构设计

## 核心问题

企业版 Codex 每周重置额度（1,875 credits = $75），但本地日志不暴露余额。
需要通过解析 Codex 本地日志来推算已用量，在多个终端实时展示。

## 解决方案

三层架构：数据采集 → 计算缓存 → 多端展示

```
┌────────────────────────────────────────────────────────────┐
│  触发层（Codex 钩子）                                        │
│  ~/.codex/hooks.json                                       │
│  ├─ PostToolUse → codex-credits-cache.sh  ← 默认安装         │
│  └─ Stop       → codex-barrage.sh          ← 弹幕模式可选     │
└──────────────┬─────────────────────────────────────────────┘
               │ 更新
               ▼
┌────────────────────────────────────────────────────────────┐
│  缓存层                                                     │
│  /tmp/codex-credits.json                                    │
│  ┌──────────────────────────────────────────────────┐       │
│  │ {credits_used, credits_pct, fresh_input,         │       │
│  │  output, models, period_start, period_end ...}   │       │
│  └──────────────────────────────────────────────────┘       │
└──────────────┬─────────────────────────────────────────────┘
               │ 读取
    ┌──────────┼──────────────┐
    ▼          ▼              ▼
┌────────┐ ┌────────┐ ┌──────────────┐
│ SwiftBar│ │ Shell  │ │ 弹幕通知     │
│ 菜单栏  │ │ 终端   │ │ 右上角弹出   │
│ Cx 7%  │ │ $codex │ │ 🟢 Codex 7% │
│ 常显    │ │ 详细   │ │ 3.5秒消失   │
└────────┘ └────────┘ └──────────────┘
```

## 文件清单

### 核心脚本

| 文件 | 作用 | 触发方式 |
|------|------|---------|
| `scripts/codex_credits_core.py` | 统一计算、报表、缓存、校准逻辑 | 被各入口调用 |
| `scripts/daily-usage.sh` | 主查询脚本 wrapper | 手动运行 |
| `scripts/codex-credits-cache.sh` | 更新 /tmp/codex-credits.json 缓存 wrapper | PostToolUse 钩子 |
| `scripts/codex-barrage.sh` | 右上角弹幕通知 | Stop 钩子 |
| `scripts/codex-menu-bar.sh` | SwiftBar 菜单栏插件 | SwiftBar 定时轮询 |

### 配置文件

| 文件 | 作用 |
|------|------|
| `~/.codex-credits.json` | 个人配置（重置时间、credits 汇率、token 权重） |
| `~/.codex/hooks.json` | Codex 钩子配置（安装脚本的地方） |
| `/tmp/codex-credits.json` | 运行时缓存（被多端读取） |

## 计费模型

### 企业版参数

| 项目 | 值 | 来源 |
|------|-----|------|
| 周限额 | 1,875 credits | OpenAI 企业版合同 |
| 等价金额 | $75.00 | 1 credit = $0.04 |
| 重置周期 | 滚动周 | 从第一条消费消息起算 |
| 重置时间 | 周三 15:16 CST | 你的首条消息时间 |

### Billable Units 计算

借鉴 ccuusage 的 Codex token bucket 模型，将不同 token 类型按权重合并为统一的 **billable unit**：

```
billable_units = fresh_input + output × output_weight + cached × cached_weight
credits       = billable_units ÷ tokens_per_credit
```

**当前校准值**（从 $75 限额窗口反推）：

```
窗口: 2026-05-27 15:16 → 2026-05-28 21:00 CST
消耗: 7,231,099 fresh_input + 233,215 output = 7,464,314 billable_units
限额: 1,875 credits
汇率: 7,464,314 ÷ 1,875 = 3,981 billable_units / credit
```

Token 权重可在 `~/.codex-credits.json` 中配置：
- `output_token_weight`：默认为 0（待校准）
- `cached_token_weight`：默认为 0（企业版通常缓存免费）

### 为什么不用 ccuusage 的定价

ccusage 使用 LiteLLM 公开 API 价格（如 gpt-5.4 输入 $2.5/M），企业版有自己的折扣率。
通过已知的 $75 限额窗口反推出符合你合同的实际费率。

## 数据流详解

### 1. 触发：Codex 钩子

`~/.codex/hooks.json` 中 Codex Credits 相关事件：

```
PostToolUse   → codex-credits-cache.sh   ← credits 实时更新
Stop          → codex-barrage.sh          ← 弹幕模式可选
```

#### PostToolUse 钩子

默认安装。每次 Codex 工具调用后立即触发，执行 `codex-credits-cache.sh`。

流程：
```
1. 读取 ~/.codex-credits.json（汇率、重置时间等配置）
2. 计算当前重置周期起点（如周三 15:16 CST）
3. 扫描 ~/.codex/sessions/**/*/rollout-*.jsonl
4. 从 turn_context 提取 model 名称
5. 从 event_msg/token_count 提取 last_token_usage 增量
6. 累加 fresh_input、output、cached
7. 按权重计算 billable_units
8. 换算 credits = billable_units ÷ tokens_per_credit
9. 写入 /tmp/codex-credits.json
```

锁机制（`/tmp/codex-credits.lock`）：1 分钟内重复触发跳过，避免并发扫描。

#### Stop 钩子

仅 `--with-barrage` 安装。Codex 会话结束后触发，执行 `codex-barrage.sh`。

流程：
```
1. 等待 1 秒（等缓存更新完成）
2. 读取 /tmp/codex-credits.json
3. 按用量百分比选择颜色（🟢🟡🟠🔴）
4. 生成通知内容（进度条 + 数字）
5. 调用 osascript display notification 弹出
```

### 2. 读取：多端展示

#### 菜单栏（SwiftBar）

SwiftBar 通过 `codex.10s.sh` 插件轮询 `/tmp/codex-credits.json`。
实际更新由 PostToolUse 钩子驱动，所以大部分轮询只是读缓存（瞬时完成）。

显示格式：
```
🟢 Codex $8 / 7%    ← 菜单栏（金额和百分比交替）
├ Overview
├ ████□□□□□□  7.0%
├ $8.00 / $75.00 · 剩余 $67.00
├ Usage
├ 输入 474K · 输出 4K · 缓存 306K
├ Billing Window
├ 2026-06-03 15:16 → 2026-06-10 15:16
├ Calibration
├ 达到限额后使用
├ 输入恢复时间，自动用恢复时间往前 7 天校准
├ ⚙️ 限额后时间窗口和额度校准
├ 🔄 刷新数据  | 📋 周明细  | 💵 设置周预算
```

#### 终端（daily-usage.sh）

`daily-usage.sh` 是主查询脚本，支持子命令：

| 命令 | 用途 |
|------|------|
| `./daily-usage.sh` | 默认摘要视图 |
| `--status` | 单行状态（适合嵌入 PS1） |
| `--weekly` | 本周逐日明细 |
| `--daily` | 每日明细 |
| `--watch` | 监控模式（5 分钟刷新） |
| `--calibrate` | 推荐入口：限额后时间窗口和额度校准 |
| `--calibrate-limit` / `--calibrate-window` | `--calibrate` 的明确别名 |
| `--set-reset` | 兼容旧命令，等同于 `--calibrate-start` |
| `--calibrate-start` | 高级入口：仅校准首次使用/重置时间 |
| `--calibrate-rate` | 高级入口：仅校准 token 单价 |
| `--set-budget` | 设置周预算 |
| `--version` | 版本信息 |

#### 右上角弹幕（codex-barrage.sh）

Stop 钩子触发，显示 3.5 秒自动消失。

```
┌──────────────────────────────────┐
│ 🟢 Codex  7%             刚刚    │
│ 用量正常                         │
│ ████░░░░░░░░  123 / 1875         │
│ 剩余 1752 credits · $4.92        │
└──────────────────────────────────┘
```

颜色随用量变化：
| 范围 | 颜色 | 副标题 | emoji |
|------|------|--------|-------|
| < 40% | 🟢 绿 | 用量正常 | 🟢 |
| 40-70% | 🟡 黄 | 用量中等 | 🟡 |
| 70-90% | 🟠 橙 | 用量警告 | 🟠 |
| >= 90% | 🔴 红 | ⚠️ 额度即将用尽 | 🔴 |

## 重置时间计算

重置是**滚动周**，基于你的第一条消费消息时间。实现方式：

```python
WEEKDAYS = ['Monday', 'Tuesday', 'Wednesday', ...]
reset_wd_num = WEEKDAYS.index('Wednesday')       # 2
current_wd = now_cst.weekday()                    # e.g., Thursday = 3
days_since_reset = (current_wd - reset_wd_num) % 7  # (3-2) % 7 = 1

period_start = now_cst - timedelta(days=days_since_reset)
period_start = period_start.replace(hour=15, minute=16, second=0)

if now_cst < period_start:
    period_start -= timedelta(days=7)  # 还没到本周重置时间
```

## 对比 ccuusage

| | ccuusage | 本方案 |
|--|----------|--------|
| 数据源 | rollout JSONL + 其他事件 | rollout JSONL |
| Model 提取 | response_item / turn_context 多源 | turn_context 为主 |
| 定价 | LiteLLM 公开价格 | 企业版合约反推的 billable units/credit |
| Credits | 不适用 | 企业版 1,875/周 |
| 显示 | 终端表格 | 菜单栏 + 弹幕 + 终端 |

## 安装步骤

### 首次安装

```bash
# 1. 安装脚本会自动探测首次使用/重置时间
bash install.sh

# 2. 安装菜单栏（可选）
brew install --cask swiftbar
mkdir -p ~/Library/SwiftBar/plugins
ln -s "$PWD/scripts/codex-menu-bar.sh" \
  ~/Library/SwiftBar/plugins/codex.10s.sh

# 3. 手动刷新缓存
bash ./scripts/codex-credits-cache.sh
```

### 校准

默认周预算为 `$75`。等一周限额用满后，用 Codex 提示的额度恢复时间校准窗口和单价：

```json
{
  "weekly_budget_dollars": 75,
  "tokens_per_credit": 3981,     // 调大 = token 更便宜
  "output_token_weight": 0,      // 0 = 输出不计费
  "cached_token_weight": 0,      // 0 = 缓存不计费
  "weekly_credits": 1875,
  "cents_per_credit": 4,
  "reset_weekday": "Wednesday",
  "reset_hour": 15,
  "reset_minute": 16
}
```

## 校准指南

### 为什么需要校准

当前 `tokens_per_credit = 3,981` 是从一个 28 小时窗口（5/27 15:16 → 5/28 21:00）反推的，存在两个不确定因素：

1. **输出 token 是否计费**：当前 `output_token_weight = 0`（假设输出免费）
2. **缓存 token 是否计费**：当前 `cached_token_weight = 0`（假设缓存免费）

需要跑完一整周来验证。

### 校准步骤

#### 第 1 步：等限额用满

正常使用 Codex，直到收到弹幕 `🔴 额度即将用尽` 或 Codex 提示配额不足。

#### 第 2 步：运行推荐校准

```bash
bash ./scripts/daily-usage.sh --calibrate
```

按提示输入：

```
当前是否已经达到周限额？y
额度恢复时间: 2026-06-10 15:16
周限额金额: 75
```

脚本会使用“额度恢复时间往前 7 天”作为完整用量窗口，反推新的 `tokens_per_credit`：

```python
tokens_per_credit = billable_units / (actual_dollars / (cents_per_credit / 100))
```

同时会保存：
- 周预算金额
- 每周重置时间
- 新的 token 单价

#### 第 3 步：验证

```bash
# 刷新缓存
bash ./scripts/codex-credits-cache.sh

# 检查
bash ./scripts/daily-usage.sh
# 应该显示接近 1875 / 1875 credits
```

### 不同校准场景

| 场景 | 现象 | 操作 |
|------|------|------|
| 限额满了但显示 < 1875 | credits_used 偏低 | ↓ 调小 tokens_per_credit |
| 限额没满但显示 > 1875 | credits_used 偏高 | ↑ 调大 tokens_per_credit |
| 限额满了刚好 1875 | ✅ 完美 | 不用调 |

## 已知限制

1. **balance 为 null**：企业版不在本地暴露余额，只能通过推算
2. **首次运行慢**：扫描 278+ 个 JSONL 文件约 5-10 秒，后续用缓存
3. **Model 提取不完整**：仅从 `turn_context` 提取，部分事件可能缺失
4. **定价需校准**：token 权重和汇率需要等一周数据验证
5. **菜单栏刷新依赖 SwiftBar**：macOS 14+ 专用
