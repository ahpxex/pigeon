# Pigeon

Pigeon 是一个 macOS 原生终端模拟器：SwiftUI 外壳 + libghostty（Ghostty 的核心库）作为终端内核。libghostty 负责 VT 解析、PTY、字体渲染（Metal，自带渲染线程）；Swift 层只负责窗口、输入事件转发和系统集成。

## 架构

```
Sources/Pigeon/
├── PigeonApp.swift          # @main SwiftUI App
├── AppDelegate.swift        # 生命周期（退出时 shutdown libghostty）
├── TerminalView.swift       # SwiftUI 根视图 + NSViewRepresentable 桥接
├── Info.plist
└── Ghostty/                 # libghostty 封装层（唯一允许 import GhosttyKit 的地方之外不要扩散）
    ├── Ghostty.swift        # 命名空间、ghostty_init、修饰键转换、NSEvent → key event
    ├── GhosttyApp.swift     # ghostty_app_t 生命周期、runtime 回调（wakeup/action/clipboard）
    └── SurfaceView.swift    # NSView：surface 创建、键盘（含 NSTextInputClient/IME）、鼠标、resize、focus

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
- **配置**：直接复用 Ghostty 的配置文件（`~/.config/ghostty/config`），`ghostty_config_load_default_files`。
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

## 当前状态与路线图

已实现（v0 脚手架）：单窗口单 surface、shell 可跑、键盘（含基本 IME preedit）、鼠标（点击/拖拽/滚轮/momentum）、剪贴板、标题（OSC 0/2）、光标形状、bell、URL 打开、Ghostty 配置加载。

已知简化（做功能时优先补这些）：
- 剪贴板读取确认（OSC 52）目前直接放行，没有像 Ghostty 那样弹确认框
- close_surface 没有"进程还活着"的确认对话框
- IME 候选框定位实现了，但 preedit 文本没有渲染到终端里（composing 状态只是不发 key）
- `GHOSTTY_ACTION_INITIAL_SIZE` / `CELL_SIZE` 被忽略，窗口不会按行列数吸附
- 无 tab、无 split、无多窗口管理、无设置界面

路线图（用户随时会调整）：tabs → splits → 窗口/外观打磨（毛玻璃、自定义标题栏）→ 设置界面 → 主题。

## 约定

- 与 libghostty 的一切交互收敛在 `Sources/Pigeon/Ghostty/` 里，UI 层不直接碰 C API。
- 参考实现永远看 `vendor/ghostty/macos/Sources/Ghostty/`（Ghostty 官方 Swift 封装，功能齐全）；Pigeon 的封装是它的精简版，补功能时先读它怎么做。
- C 字符串生命周期：`ghostty_input_key_s.text` 等指针字段只在 `withCString` 闭包内有效，不要存。
- 升级 Ghostty：改 `scripts/setup.sh` 里的 `GHOSTTY_TAG`，重跑 fetch + build，然后对着 `include/ghostty.h` 的 diff 修编译错误。
