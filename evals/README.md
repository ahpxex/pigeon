# Agent evals

评测走**真实链路**：用例直接 POST 到 app 内 AgentServer 的 `/ask`（token 通过驱动的
`/agent/info` 获取），agent loop、工具执行、Markdown→ANSI 渲染、鉴权全部按生产路径跑。

## 两个套件

| 套件 | 用途 | LLM |
|------|------|-----|
| `cases/regression.json` | 确定性回归：渲染、工具循环、轮次预算、拒绝逻辑 | `mock_llm.py`（脚本化 turns，runner 自动拉起） |
| `cases/live.json` | 质量评测：典型微任务的行为断言 + 延迟 | 真实 Provider（须已在设置里配好 key） |

每次运行还固定执行**安全预检**：`/ask` 对无 token / 错 token / 带 Origin /
非 loopback Host 的请求必须全部 403（守住 CLAUDE.md 里的安全红线）。

## 运行

```sh
scripts/pigeonctl launch                 # 前提：app 在驱动模式下运行
python3 evals/run.py                     # 回归套件（无网络、无 key）
python3 evals/run.py --suite evals/cases/live.json --live \
    --provider DeepSeek                  # 质量套件（可 --model 覆盖）
python3 evals/run.py --only markdown --verbose   # 过滤 + 失败时打印输出
```

退出码非 0 即有失败。runner 会在结束时恢复原来的默认 Provider，
并清理临时的 `PigeonEvalMock` Provider 和 fixture 目录。

## 写用例

见 `run.py` 顶部 docstring 的 schema。要点：

- **regression 用例**带 `turns`（脚本化的助手回合，第 N 个回合应答 loop 的第 N 轮）；
  mock 按 `prompt` 子串匹配场景，所以 prompt 必须彼此不重叠。
- **live 用例**不带 `turns`，需要 `--live` 才会跑（否则跳过并提示）。
- `fixture` 造临时 cwd：键以 `/` 结尾建目录，值为 `{"repeat": "x", "n": 20000}`
  可生成大文件。
- 断言在 ANSI 剥离后的文本上跑；`raw_contains` / `raw_not_contains` 用于
  验证 ANSI 渲染本身（JSON 里用 `\u001b` 写 ESC）。
- mock 的 SSE 按 7 字符切 chunk，天然覆盖"markdown 标记跨 chunk 边界"的场景。

## 已知边界 / 后续方向

- 语言一致性（中文问中文答）没有可靠的程序化断言，需要 LLM judge —— 未做。
- live 套件目前 6 个用例，跑一轮约 1-2 分钟；扩充时优先加"产品定位"里的
  日常微任务（端口进程、报错解释、找文件）。
- 尚无 CI 集成；regression 套件无外部依赖，适合作为提交前检查。
