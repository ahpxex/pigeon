# Agent evals

评测走**真实链路**：用例直接 POST 到 app 内 AgentServer 的 `/ask`（token 通过驱动的
`/agent/info` 获取），agent loop、工具执行、确认协议、Markdown→ANSI 渲染、鉴权、
对话记忆全部按生产路径跑。

Harness 是 `evals/` 下的独立 SwiftPM 包（`pigeon-eval`），与 app 的 xcodeproj 无关；
mock LLM 在 runner 进程内起（NWListener SSE），没有子进程。⚠️ 入口用
`scripts/eval`（固定 `/usr/bin/swift` = Xcode toolchain）——PATH 里 swiftly 的
自装 toolchain 和系统 SDK 不兼容。

## 两个套件

| 套件 | 用途 | LLM |
|------|------|-----|
| `cases/regression.json` | 确定性回归：渲染、工具循环、确认协议、记忆、拒绝逻辑 | 进程内 mock（脚本化 turns） |
| `cases/live.json` | 质量评测:典型微任务的行为断言 + 延迟 | 真实 Provider（须已在设置里配好 key） |

每次运行还固定执行**安全预检**：`/ask` 和 `/confirm` 对无 token / 错 token /
带 Origin / 非 loopback Host 的请求必须全部 403。

## 运行

```sh
scripts/pigeonctl launch                 # 前提：app 在驱动模式下运行
scripts/eval                             # 回归套件（无网络、无 key）
scripts/eval --suite evals/cases/live.json --live --provider DeepSeek
scripts/eval --only markdown --verbose   # 过滤 + 失败时打印输出
```

退出码非 0 即有失败。runner 结束时恢复原默认 Provider，清理 `PigeonEvalMock`
和 fixture 目录。

## 写用例

schema（JSON，见 `cases/*.json`）：

- `name` / `prompt`：唯一标识；mock 按 `prompt` 子串匹配场景，prompt 间不要互为子串。
- `turns`（回归用例）：脚本化助手回合，第 N 回合应答 loop 的第 N 轮（按最后一条
  user 消息之后的 assistant 数计轮）。`{"text":...}`、`{"tool_calls":[{name,arguments}]}`、
  `{"echo_user_count": true}`（回 `user_count=N`，测记忆）。不带 `turns` 的是 live
  用例，需 `--live` 才跑。
- `fixture`：造临时 cwd。值为字符串=文件内容；`{"repeat":"x","n":20000}` 生成大文件；
  键以 `/` 结尾建目录。
- `confirm`：`"allow"`/`"deny"`（默认 deny）——对确认哨兵的应答；捕获文本中以
  `[confirm-request] <display>` 出现。
- `surface`：对话记忆键；同 surface 的用例组成一段对话（按文件顺序）。runner 会
  拼 per-run 后缀保证运行间隔离。
- `expect` 断言（在 ANSI 剥离后的文本上跑，`raw_*` 除外）：
  `contains` / `not_contains` / `regex` / `raw_contains` / `raw_not_contains`（JSON 里
  用 `\u001b` 写 ESC）/ `count`(+`n`) / `tool_used` / `max_lines`(`n`) /
  `max_seconds`(`n`) / `no_error` / `fixture_exists`(+可选 `contains`) /
  `fixture_missing` / `single_trailing_newline`。

mock 的 SSE 按 7 字符切 chunk，天然覆盖"markdown 标记跨 chunk 边界"的场景。

## 已知边界 / 后续方向

- 语言一致性（中文问中文答）没有可靠的程序化断言，需要 LLM judge —— 未做。
- 屏幕注入没有自动化用例（需要真实 surface），靠手动 pigeonctl 流程验证。
- 尚无 CI 集成；regression 套件无外部依赖，适合作为提交前检查。
