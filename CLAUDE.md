# Pigeon

Pigeon 是一个 macOS 原生终端模拟器：SwiftUI 外壳 + libghostty（Ghostty 的核心库）作为终端内核。libghostty 负责 VT 解析、PTY、字体渲染（Metal，自带渲染线程）；Swift 层只负责窗口、输入事件转发和系统集成。

## 架构

```
Sources/Pigeon/
├── PigeonApp.swift          # @main SwiftUI App（Window scene，hiddenTitleBar）
├── AppDelegate.swift        # 生命周期、激活策略、启动 DriverServer
├── TerminalView.swift       # 工作区：自绘垂直 Tab 侧边栏 + 多 surface 保活切换
├── TabModel.swift           # TerminalTab / TabManager（tab 生命周期与选中态）
├── Info.plist
├── Automation/
│   └── DriverServer.swift   # 调试驱动服务（localhost HTTP，PIGEON_DRIVER_PORT 开启）
└── Ghostty/                 # libghostty 封装层（不要把 C API 扩散到这层之外）
    ├── Ghostty.swift        # 命名空间、ghostty_init、修饰键转换、NSEvent → key event
    ├── GhosttyApp.swift     # ghostty_app_t 生命周期、runtime 回调、配置色读取
    └── SurfaceView.swift    # NSView：surface、键盘（含 IME）、鼠标、resize、focus、文本注入/读回

vendor/                      # 全部 gitignore，由 scripts/setup.sh 重建
├── ghostty/                 # Ghostty 源码，固定 tag v1.2.3
│   └── macos/GhosttyKit.xcframework   # zig 构建产物（静态库 + 头文件）
├── zig-cache/               # zig 依赖缓存（离线灌入）
└── downloads/               # curl/git 下载的依赖原始文件
```

关键机制：

- **libghostty 自己渲染**。它往 SurfaceView 上挂 CAMetalLayer 并在独立线程画图。Swift 层不调用任何绘制 API，只需要在 resize/scale 变化时调 `ghostty_surface_set_size` / `set_content_scale`（单位是物理像素）。
- **事件循环**：libghostty 的 `wakeup_cb` 可能从任意线程来，必须 dispatch 到主线程再调 `ghostty_app_tick`。所有 action 回调里碰 AppKit 的代码同样要回主线程。
- **回调 userdata 约定**：app 级回调的 userdata 是 `Ghostty.App`，surface 级回调（clipboard、close_surface）的 userdata 是 `SurfaceView`。从 `ghostty_surface_t` 反查视图用 `ghostty_surface_userdata`。
- **键盘**：keyDown 先过 `interpretKeyEvents`（走 IME），把产生的文本挂到 key event 的 `text` 字段再交给 `ghostty_surface_key`；cmd 组合键走 `performKeyEquivalent`，先用 `ghostty_surface_key_is_binding` 探测，不是 binding 就放行给菜单。
- **配置**：Pigeon 有独立的内核配置 `~/.config/pigeon/config`（Ghostty 格式，首启从 Ghostty 配置导入一次做起点，之后互不影响）。libghostty 没有指定路径加载的 C API，`GhosttyConfigStore` 在加载瞬间把 HOME/XDG_CONFIG_HOME 指向私有沙盒（内含指向真实文件的 symlink），加载完还原，finalize 在还原后做（保证 ~ 展开正确）。支持热重载：设置里的 Reload 按钮、ghostty 键位 reload_config、驱动 /config/reload 都走 `ghostty_app_update_config`。
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
- 链接需要 `-lstdc++`（libghostty-fat.a 里静态包了 harfbuzz 等 C++ 依赖），已写在 project.yml。
- App 不能开沙盒（终端要以用户权限起 shell），和 Ghostty/iTerm2 一样。

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
scripts/pigeonctl reload-config             # 重载 ~/.config/pigeon/config
scripts/pigeonctl settings ['{"labelStyle":"fullPath"}']   # 读/改设置（labelStyle iconCategory appearance accentHex）|none> / group-expand <id> <true|false>|none>
scripts/pigeonctl screenshot x.png# 用 state 里的 windowNumber 精确截窗口
scripts/pigeonctl quit
```

典型断言流：`run 'echo marker-$((6*7))'` → sleep → `text | grep marker-42`。截图看视觉，text 做断言。注意：

- **必须用 pigeonctl launch 启动**。从后台 shell 直接 exec 二进制会得到无头进程（SwiftUI 场景不实例化、NSApp.windows 为空），这不是 bug 是 macOS 行为。
- 新建 tab 后要等 shell 出 prompt 再 `run`（约 0.5-1s），否则输入会混进启动 banner。
- 所有驱动请求在主线程处理，直接调 TabManager / SurfaceView，与真实交互同路径（但绕过了 AppKit 事件层 —— 键盘快捷键类问题驱动测不到，要单独想办法）。

## 当前状态与路线图

已实现：垂直 Tab 侧边栏（多 tab、切换保活、关闭、拖拽排序（组内）、右键重命名（customTitle 覆盖 shell 标题）、cmd+T/W、cmd+1-9 走 ghostty 键位；拖拽调宽 160-420、拖到 <120 或 ⌥⌘S 折叠，状态持久化在 UserDefaults，`WorkspaceState`）、窗口配色与终端主题统一（hiddenTitleBar 全铺背景色）、分组（TabGroup：折叠/改名/删除，右键 Move to Group，侧边栏空白处单击新建组并行内命名（空名=取消），拖拽 tab 到组头或组区域直接入组（高亮提示），组内拖拽排序，空组保留到手动删除）、OpenMoji tab 图标（56 个精选 128px PNG 分五类打进 bundle，新 tab 随机分配且避开在用图标，右键 Change Icon 弹分类网格选择器；OpenMoji CC BY-SA 4.0 需保留署名）、驱动服务与 pigeonctl、键盘（含基本 IME preedit）、鼠标、剪贴板、标题（默认显示 OSC 7 上报的目录名，custom rename 优先）、按住 ⌘ 显示 tab 跳转序号（cmd+1-9 按侧边栏视觉顺序）、光标形状、bell、URL 打开、Ghostty 配置加载。

已知简化（做功能时优先补这些）：
- 剪贴板读取确认（OSC 52）目前直接放行，没有像 Ghostty 那样弹确认框
- close_surface 没有"进程还活着"的确认对话框；tab 关闭即杀 shell
- IME 候选框定位实现了，但 preedit 文本没有渲染到终端里（composing 状态只是不发 key）
- `GHOSTTY_ACTION_INITIAL_SIZE` / `CELL_SIZE` 被忽略，窗口不会按行列数吸附
- 无 split、无多窗口管理、无设置界面；配置热重载未接（改 ghostty config 要重启）

已有设置界面（⌘, 打开，SwiftUI Settings scene 分四个 Tab）：General（标签风格、图标分类，`AppSettings`）、Appearance（系统/亮/暗、主题色）、Terminal（内核 GUI 设置：字体/字号/前背景色/光标/不透明度，`KernelSettings` 写进配置文件末尾的 pigeon-settings 托管块并热重载，块外内容留给手改且被托管块覆盖）、Advanced（配置文件路径/打开/重载）。程序化打开设置窗口必须走 SwiftUI openSettings 环境动作（`SettingsOpener` 桥接 + `.pigeonOpenSettings` 通知）—— showSettingsWindow: 等老 selector 在 macOS 26 上已失效；cmd+, 在 performKeyEquivalent 里明确不给 ghostty（它默认绑成 open_config）。

路线图（用户随时会调整）：splits → 多窗口 → 主题。

## 约定

- 与 libghostty 的一切交互收敛在 `Sources/Pigeon/Ghostty/` 里，UI 层不直接碰 C API。
- 参考实现永远看 `vendor/ghostty/macos/Sources/Ghostty/`（Ghostty 官方 Swift 封装，功能齐全）；Pigeon 的封装是它的精简版，补功能时先读它怎么做。
- C 字符串生命周期：`ghostty_input_key_s.text` 等指针字段只在 `withCString` 闭包内有效，不要存。
- 升级 Ghostty：改 `scripts/setup.sh` 里的 `GHOSTTY_TAG`，重跑 fetch + build，然后对着 `include/ghostty.h` 的 diff 修编译错误。
