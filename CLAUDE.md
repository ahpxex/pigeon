# Pigeon

Pigeon 是一个 macOS 原生的 **agentic 终端模拟器**：SwiftUI 外壳 + libghostty（Ghostty 的核心库）作为终端内核。libghostty 负责 VT 解析、PTY、字体渲染（Metal，自带渲染线程）；Swift 层负责窗口、输入事件转发、系统集成，以及 Pigeon 的差异化能力 —— 内置 Agent。

## 产品定位

Pigeon 的特色是"终端自带一个轻量 Agent"。设计边界要牢记：

- **不是** Claude Code / Codex 那种强 Agent 的替代品，不做多步规划、不做大型代码改造。
- 目标是那些"为它专门开一个强 Agent 太重"的日常小任务：看看这个目录里有什么、帮我找某个文件、整理一下这个目录、看看 3000 端口跑的是什么进程、这条报错什么意思……一句话进，一个动作或一句答案出。
- 用户在设置的 Agent Tab 配置 AI Provider（内置 Anthropic/OpenAI/DeepSeek + 自定义 OpenAI 兼容端点），模型可选、API key 按 Provider 独立存 `~/.config/pigeon/credentials.json`（0600）—— 这套配置就是给内置 Agent 用的。⚠️ 别改回 Keychain：Keychain ACL 绑定代码签名身份，对自编译 app 意味着重编译/更新后反复弹授权框（已踩过）。内置 Provider 的 UUID 是写死的常量，key 按 UUID 索引，UUID 不稳定会让 key 变孤儿。
- 由此推论：实现上优先低延迟、低成本（小模型可用）、单轮或极少轮工具调用；宁可把任务做小做快，不做长链路。

## 架构

```
Sources/Pigeon/
├── App/                     # 入口与全局状态
│   ├── PigeonApp.swift      #   @main（Window scene，hiddenTitleBar，Settings scene，菜单）
│   ├── AppDelegate.swift    #   生命周期、激活策略、外观应用、启动 DriverServer
│   ├── AppSettings.swift    #   Pigeon 外壳设置（标签风格/图标分类/外观/主题色，UserDefaults）
│   └── WorkspaceState.swift #   侧边栏宽度/折叠（UserDefaults）
├── Ghostty/                 # libghostty 封装层（不要把 C API 扩散到这层之外）
│   ├── Ghostty.swift        #   命名空间、ghostty_init、修饰键转换、NSEvent → key event
│   ├── GhosttyApp.swift     #   ghostty_app_t 生命周期、runtime 回调、配置读值、reload
│   ├── GhosttyConfigStore.swift # 配置文件管理 + ghostty_config_load_file 加载
│   ├── KernelSettings.swift #   GUI 管理的内核设置（托管块写入 + 热重载）
│   ├── SurfaceView.swift    #   NSView：surface、键盘（含 IME）、鼠标、resize、focus、注入/读回
│   └── TerminalTheme.swift  #   内置主题目录（bg/fg/16 色 palette）
├── Tabs/
│   ├── TabModel.swift       #   TerminalTab / TabGroup / TabManager
│   └── TabIcon.swift        #   OpenMoji 目录与缓存
├── Workspace/               # 主窗口 UI
│   ├── TerminalView.swift   #   根视图 + 工作区布局 + 窗口透明 + Settings 桥
│   ├── TerminalSurface.swift#   NSViewRepresentable 桥接
│   └── Sidebar/
│       ├── TabSidebar.swift #   列表结构 + 拖拽排序/入组 + resize 手柄
│       ├── TabRow.swift     #   行：图标/标题/改名/右键菜单/⌘N 徽标
│       ├── GroupHeaderRow.swift # 组头：折叠/改名/删除
│       └── IconPicker.swift #   图标网格选择器
├── Settings/                # 设置窗口，一 Tab 一文件
│   ├── SettingsView.swift / GeneralSettingsTab / AppearanceSettingsTab
│   └── TerminalSettingsTab / AgentSettingsTab / AdvancedSettingsTab
├── Agent/
│   └── AgentSettings.swift  #   AI Provider 配置 + credentials 文件 + /models 拉取
├── Automation/
│   └── DriverServer.swift   #   调试驱动服务（localhost HTTP，PIGEON_DRIVER_PORT 开启）
├── Resources/OpenMoji/      # 56 个图标 PNG
├── Assets.xcassets          # AppIcon
└── Info.plist

patches/                     # 对 vendor/ghostty 的本地补丁（setup.sh 自动应用）
vendor/                      # 全部 gitignore，由 scripts/setup.sh 重建
├── ghostty/                 # Ghostty 源码，固定 tag v1.2.3 + patches/
│   └── macos/GhosttyKit.xcframework   # zig 构建产物（静态库 + 头文件）
├── zig-cache/               # zig 依赖缓存（离线灌入）
└── downloads/               # curl/git 下载的依赖原始文件
```

分层规则：App（全局状态）→ Workspace/Settings（UI）→ Tabs（模型）→ Ghostty（内核封装）。UI 不直接碰 GhosttyKit 的 C API；新功能先想清楚归哪层，单文件超过 ~300 行就该考虑拆。

关键机制：

- **libghostty 自己渲染**。它往 SurfaceView 上挂 CAMetalLayer 并在独立线程画图。Swift 层不调用任何绘制 API，只需要在 resize/scale 变化时调 `ghostty_surface_set_size` / `set_content_scale`（单位是物理像素）。
- **background-opacity 需要 app 配合**：内核渲染层带 alpha，但 NSWindow 必须 isOpaque=false、SwiftUI 铺底色也要乘同样的 opacity（`WindowTransparencyConfigurator`），否则设置了也看不见。
- **配置热重载必须双管齐下**：`ghostty_app_update_config` 只更新 app 级状态，活着的 surface 要逐个调 `ghostty_surface_update_config`，否则字体/颜色改了不生效（Ghostty 官方也是这么做的）。
- **事件循环**：libghostty 的 `wakeup_cb` 可能从任意线程来，必须 dispatch 到主线程再调 `ghostty_app_tick`。所有 action 回调里碰 AppKit 的代码同样要回主线程。
- **回调 userdata 约定**：app 级回调的 userdata 是 `Ghostty.App`，surface 级回调（clipboard、close_surface）的 userdata 是 `SurfaceView`。从 `ghostty_surface_t` 反查视图用 `ghostty_surface_userdata`。
- **键盘**：keyDown 先过 `interpretKeyEvents`（走 IME），把产生的文本挂到 key event 的 `text` 字段再交给 `ghostty_surface_key`；cmd 组合键走 `performKeyEquivalent`，先用 `ghostty_surface_key_is_binding` 探测，不是 binding 就放行给菜单。
- **配置**：Pigeon 有独立的内核配置 `~/.config/pigeon/config`（Ghostty 格式，首启从 Ghostty 配置导入一次做起点，之后互不影响）。libghostty 没有指定路径加载的 C API，我们给内核加了正式的嵌入方 API（`patches/ghostty-embedder-api.patch`，setup.sh 自动应用）：`ghostty_config_load_file(config, path)` 直接从指定路径加载，不碰默认搜索路径，也没有环境变量。改内核让它适配 Pigeon 是正当手段 —— 我们从源码构建，补丁收在 patches/ 下。⚠️ 别退回 HOME/XDG env-swap 方案：Foundation 会缓存 NSSearchPath 结果，AppKit 用真实 HOME 解析过一次后 swap 就失效，表现为"配置隔离时好时坏"。支持热重载：设置里的 Reload 按钮、ghostty 键位 reload_config、驱动 /config/reload 都走 `ghostty_app_update_config`。
- **窗口配色**：hiddenTitleBar + 全窗口铺 `ghostty_config_get("background")` 读出的终端背景色；侧边栏是前景色 6% 透明度的浮层。刻意不用 NavigationSplitView（它的毛玻璃透出的是桌面，和终端色对不上）。
- **Tabs**：`TabManager.shared` 持有 tab 列表；每个 tab 的 SurfaceView 常驻视图树（ZStack + opacity 切换），shell 进程不因切走而中断。ghostty 键位（cmd+T/W、cmd+1-9、cmd+shift+[]）通过 action 回调 → NotificationCenter（`.pigeonNewTab` 等）→ TabManager。close_surface（进程退出）同样走关 tab 路径，最后一个 tab 关掉时关窗口。
- **文本注入有两条通道**：`ghostty_surface_text` 走粘贴路径（bracketed paste，控制字符不会被执行！），`ghostty_surface_key` 走按键编码路径。模拟"按回车"必须用后者 —— DriverServer 的 /input/text vs /input/key 就是这两条。
- **资源**：app bundle 的 `Contents/Resources/{ghostty,terminfo}` 由 Xcode post-build 脚本从 `vendor/ghostty/zig-out/share/` rsync 过来，libghostty 按 Ghostty.app 的相对布局自动找到（TERM=xterm-ghostty 的 terminfo、shell integration 都在里面）。

## 构建

```sh
scripts/setup.sh        # 全新 checkout 一键搞定（克隆、依赖、构建、生成工程）
xcodegen generate       # project.yml 改了之后重新生成 Pigeon.xcodeproj
xcodebuild -project Pigeon.xcodeproj -scheme Pigeon build
open build/Build/Products/Debug/Pigeon.app   # 或从 Xcode 跑
```

只改 Swift 代码时不需要重跑 zig；改了 vendor/ghostty 或升级 tag 才需要 `scripts/build-ghostty.sh`（native）/ `scripts/build-ghostty.sh universal`（发布用双架构）。

### 构建环境的坑（都已在脚本里处理，但要知道为什么）

- **zig 版本必须 0.14.x**（Ghostty v1.2.3 要求；系统的 zig 0.15 编不过）。用 keg-only 的 `brew install zig@0.14`，路径 `/opt/homebrew/opt/zig@0.14/bin/zig`。
- **zig 的 HTTP 客户端过不了本机代理**（127.0.0.1:7890，CONNECT 报 400），所以依赖不能靠 `zig build` 自己拉。`scripts/fetch-ghostty-deps.sh` 用 curl/git（走代理没问题）下载后 `zig fetch <本地路径>` 灌进 `vendor/zig-cache`，内容 hash 照常校验。
- **iTerm2-Color-Schemes 主题包上游 404**（release asset 被删）。它是 lazy 依赖，构建时用 `-Demit-themes=false` 跳过。以后想要主题需另找该 tarball 或升级 Ghostty tag。
- **Xcode 26 的 Metal 工具链是可选组件**，缺了会报 "cannot execute tool 'metal'"：`xcodebuild -downloadComponent MetalToolchain`。
- **Debug 构建用本地自签证书 "Pigeon Dev" 签名**（project.yml `CODE_SIGN_IDENTITY`），新机器先跑一次 `scripts/dev-signing-setup.sh`（生成+导入+信任+partition list，中途要输两次密码）。别退回 ad-hoc（`-`）签名：代码身份每次构建都变。构建时如果 xcodebuild 长时间无输出，先查 SecurityAgent 弹框（codesign 等钥匙授权）。
- 链接需要 `-lstdc++`（libghostty-fat.a 里静态包了 harfbuzz 等 C++ 依赖），已写在 project.yml。
- App 不能开沙盒（终端要以用户权限起 shell），和 Ghostty/iTerm2 一样。

## Agent（终端原生入口）

入口就是终端本身：输入合法命令照常执行；首词不是命令时 zsh 调 `command_not_found_handler`（构建时追加到打包的 shell integration，`scripts/pigeon-integration.zsh`），整行作为自然语言 curl 到 app 内的 AgentServer（常驻 localhost，端口经 surface env `PIGEON_AGENT_PORT` 注入），回答以 chunked 流直接打回 pty（工具行灰色 ANSI）。Ctrl+C 打断 curl 即取消。

运行时架构抄 Pi 的设计语法（等效 Swift 实现在 `Agent/`）：ChatStreamClient 遵守"永不 throw"契约（错误编码进事件流）；AgentRuntime 是 ≤6 轮的顺序工具 loop；事件类型化（AgentEvent）。工具按可恢复性分档：只读（run_command/list_dir/read_file）与可恢复变更（mv/cp/mkdir/chmod/git add·commit、写新文件、`trash`=原生 FileManager.trashItem 进废纸篓）都自由执行；只有**不可逆调用**（rm、git clean、git reset --hard、覆盖已有文件）逐次要用户确认——敏感性由工具按"这一次调用"判定（`confirmationRequest(arguments:cwd:)` 返回非 nil），不是按工具整体。删除的首选是 trash 不是 rm（提示语已引导）。纯 ASCII 单短词不触发 agent（多半是敲错命令），含 CJK 的输入一律视为自然语言。DeepSeek 是一等公民（OpenAI 兼容 /chat/completions + SSE + function calling），任何同协议端点即插即用。

**确认协议（自然语言优先）**：确认内容是模型传的 `intent`（用户语言的一句"将会发生什么"，如"将永久删除 bbb.txt，此操作无法恢复"），命令本身只作为一行暗色 `→ rm bbb.txt` 审计行。流程：runtime 执行前调 RunConfig.confirm(message, command)（nil=拒绝）；AgentServer 往流里发暗色命令行 + 哨兵行 `\x01PIGEON_CONFIRM\x01<id>\x01<message>`，zsh 钩子逐行读流、认出哨兵后在 /dev/tty 上问 `⚠ <message> — allow? [y/N]`，答案 POST 回 `/confirm`（与 /ask 同一套鉴权），ConfirmationBroker 唤醒等待的 agent；120s 无应答或 Ctrl+C（连接断）都算拒绝。拒绝作为工具结果喂回模型（提示语要求它不要重试）。可变命令白名单只含本地操作（git push/pull/fetch 拒绝），依旧 argv 数组直接 exec 永不过 shell。

**安全（这两条是硬红线，别退回去）：**
- **AgentServer 是本地 RCE 级端点，必须鉴权**。绑 127.0.0.1 不是信任边界 —— 浏览器标签页能 POST、DNS rebinding 能绕、本机其他进程能读。每个 `/ask` 请求必须：带每次启动新生成的 bearer token（`PIGEON_AGENT_TOKEN`，随端口一起注入 surface env，常量时间比较）、Host 精确等于 `127.0.0.1:<port>`/`localhost:<port>`、不带任何 Origin 头。三者缺一即 403。
- **命令工具走 argv 数组 + 直接 Process exec，永不过 shell**。模型传 `{"pipeline":[["ls","-la"],["wc","-l"]]}`，每个元素是一个 exec 参数、逐字传递 —— 根本没有 shell 元字符/引号/注入面（黑名单过滤字符串是死路，别走回头路）。纵深防御：binary 只解析白名单里的裸名到绝对路径（`RunReadOnlyCommand.searchDirs`）；per-binary 危险 flag 拒绝（find 的 `-exec/-delete/...`、git 的 `-c/--exec-path/...`）；git 还要求子命令在只读白名单里。管道用 Swift `Pipe()` 串多个 Process，不交给 zsh。

**输出渲染**：助手文本经 `Agent/Render/MarkdownANSIRenderer` 流式转成 ANSI（粗体/斜体/`code` 青色/标题/列表 •/引用 ▌/围栏代码/OSC 8 链接），按行缓冲——inline 标记可能跨 chunk 但不会跨行，所以整行攒齐再渲染。系统提示允许简单 markdown（表格除外，渲染不了）。工具行等非 markdown 输出穿插前要先 flush 渲染器。

**Eval**（`evals/`，改 agent 相关代码后必须跑）：`python3 evals/run.py` 走真实 `/ask` 链路跑确定性回归（mock LLM 脚本化 turns：渲染、工具循环、轮次预算、拒绝逻辑）+ 安全预检（无 token/错 token/Origin/坏 Host 必须 403）；`--suite evals/cases/live.json --live --provider DeepSeek` 跑真实 Provider 质量套件。详见 evals/README.md。

已知改进点：语言一致性 eval 需要 LLM judge；确认应答目前只有 y/N 两态（没有"本次会话总是允许"）；`intent` 缺失时确认文案回落到 "Run: <argv>"（英文）。

## 自动化测试（驱动服务）

**改 UI/交互后必须用驱动服务自测**，不要靠 AppleScript 或肉眼。app 内置一个 localhost HTTP 驱动（`Automation/DriverServer.swift`），设了 `PIGEON_DRIVER_PORT` 才启动，只绑 127.0.0.1。`scripts/pigeonctl` 是包装：

```sh
scripts/pigeonctl launch          # 启动（走 LaunchServices + launchctl setenv 传端口）
scripts/pigeonctl state           # tab 列表 + windowNumber（JSON）
scripts/pigeonctl new-tab / select <id> / close <id>
scripts/pigeonctl run 'echo hi'   # 输入命令并回车
scripts/pigeonctl key enter|escape|tab|up|down|ctrl-c|...
scripts/pigeonctl text            # 读回整屏文本 —— 断言用这个
scripts/pigeonctl sidebar [show|hide|<width>]  # 侧边栏状态/折叠/宽度
scripts/pigeonctl move <id> <index> / rename <id> <名字>  # 排序、重命名（空名字恢复 shell 标题）
scripts/pigeonctl icon <id> <code> / group-new <名字> / group-assign <tabid> <groupid|none> / group-expand <id> <true|false>
scripts/pigeonctl（另有 /agent/provider 端点配置 Provider+key，测试 agent 用 mock LLM：见 git 历史里的 mock_llm.py 模式）
scripts/pigeonctl reload-config             # 重载 ~/.config/pigeon/config
scripts/pigeonctl settings ['{"labelStyle":"fullPath"}']   # 读/改设置（labelStyle iconCategory appearance accentHex）|none> / group-expand <id> <true|false>|none>
scripts/pigeonctl screenshot x.png# 用 state 里的 windowNumber 精确截窗口
scripts/pigeonctl quit
```

典型断言流：`run 'echo marker-$((6*7))'` → sleep → `text | grep marker-42`。截图看视觉，text 做断言。注意：

- **必须用 pigeonctl launch 启动**。从后台 shell 直接 exec 二进制会得到无头进程（SwiftUI 场景不实例化、NSApp.windows 为空），这不是 bug 是 macOS 行为。
- 新建 tab 后要等 shell 出 prompt 再 `run`（约 0.5-1s），否则输入会混进启动 banner。
- 所有驱动请求在主线程处理，直接调 TabManager / SurfaceView，与真实交互同路径（但绕过了 AppKit 事件层 —— 键盘快捷键类问题驱动测不到，要单独想办法）。
- ⚠️ 驱动的 `/input/key` 发 ctrl-u/ctrl-c 之类组合键时，键码可能以 CSI-u 片段形式漏进 zle 缓冲区（表现为行里出现 `;5u` 字样、行没被清掉）。测试要清行时别依赖 ctrl 键，改用 enter 把行跑掉或开新 tab。

## 当前状态与路线图

已实现：垂直 Tab 侧边栏（多 tab、切换保活、关闭、拖拽排序（组内）、右键重命名（customTitle 覆盖 shell 标题）、cmd+T/W、cmd+1-9 走 ghostty 键位；拖拽调宽 160-420、拖到 <120 或 ⌥⌘S 折叠，状态持久化在 UserDefaults，`WorkspaceState`）、窗口配色与终端主题统一（hiddenTitleBar 全铺背景色）、分组（TabGroup：折叠/改名/删除，右键 Move to Group，侧边栏空白处单击新建组并行内命名（空名=取消），拖拽 tab 到组头或组区域直接入组（高亮提示），组内拖拽排序，空组保留到手动删除）、OpenMoji tab 图标（56 个精选 128px PNG 分五类打进 bundle，新 tab 随机分配且避开在用图标，右键 Change Icon 弹分类网格选择器；OpenMoji CC BY-SA 4.0 需保留署名）、驱动服务与 pigeonctl、键盘（含基本 IME preedit）、鼠标、剪贴板、标题（默认显示 OSC 7 上报的目录名，custom rename 优先）、按住 ⌘ 显示 tab 跳转序号（cmd+1-9 按侧边栏视觉顺序）、光标形状、bell、URL 打开、Ghostty 配置加载。

已知简化（做功能时优先补这些）：
- 剪贴板读取确认（OSC 52）目前直接放行，没有像 Ghostty 那样弹确认框
- close_surface 没有"进程还活着"的确认对话框；tab 关闭即杀 shell
- IME 候选框定位实现了，但 preedit 文本没有渲染到终端里（composing 状态只是不发 key）
- `GHOSTTY_ACTION_INITIAL_SIZE` / `CELL_SIZE` 被忽略，窗口不会按行列数吸附
- 无 split、无多窗口管理、无设置界面；配置热重载未接（改 ghostty config 要重启）

已有设置界面（⌘, 打开，SwiftUI Settings scene 分四个 Tab）：General（标签风格、图标分类，`AppSettings`）、Appearance（系统/亮/暗、主题色）、Terminal（内核 GUI 设置：字体=系统等宽字体枚举 Picker、字号滑杆、9 个内置主题卡片（One Dark/GitHub/Solarized/Dracula/Nord/Tokyo Night/Monokai，写完整 16 色 palette）、光标、不透明度；`KernelSettings` 写进配置文件末尾的 pigeon-settings 托管块并热重载，块外内容留给手改且被托管块覆盖）、Agent（AI Provider 管理：顶部 Picker 选 Provider（选中即默认），下方只显示选中者的配置——内置 Anthropic/OpenAI/DeepSeek + 自定义 Provider（URL+模型+key），模型列表不硬编码——key 填好后自动从 /models 端点拉取（改 key/URL 防抖重拉，手动刷新保留），拉到的列表持久化当缓存，API key 每个 Provider 单独存 `~/.config/pigeon/credentials.json`，`AgentSettings`）、Advanced（配置文件路径/打开/重载）。程序化打开设置窗口必须走 SwiftUI openSettings 环境动作（`SettingsOpener` 桥接 + `.pigeonOpenSettings` 通知）—— showSettingsWindow: 等老 selector 在 macOS 26 上已失效；cmd+, 在 performKeyEquivalent 里明确不给 ghostty（它默认绑成 open_config）。

路线图（用户随时会调整）：Agent 打磨（多轮上下文记忆、屏幕内容注入）→ splits → 多窗口。

## 约定

- 与 libghostty 的一切交互收敛在 `Sources/Pigeon/Ghostty/` 里，UI 层不直接碰 C API。
- 参考实现永远看 `vendor/ghostty/macos/Sources/Ghostty/`（Ghostty 官方 Swift 封装，功能齐全）；Pigeon 的封装是它的精简版，补功能时先读它怎么做。
- C 字符串生命周期：`ghostty_input_key_s.text` 等指针字段只在 `withCString` 闭包内有效，不要存。
- 升级 Ghostty：改 `scripts/setup.sh` 里的 `GHOSTTY_TAG`，重跑 fetch + build，然后对着 `include/ghostty.h` 的 diff 修编译错误；确认 `patches/` 下的补丁还能干净应用。
- `font-family` 是可重复键（回退链）：GUI 切换字体要先写 `font-family = `（空值重置列表）再写新值，否则只是追加 fallback 永远不生效；这类键也无法用 ghostty_config_get 读回，GUI 状态存 UserDefaults。
