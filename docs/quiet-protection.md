# Codex 防亮屏保护

部分 Codex 后台检查通过电脑操作服务请求屏幕状态，即使没有实际点击，也可能创建使显示器保持亮屏的电源声明。任务里的调用检查无法拦截 Codex 主程序直接发给服务的请求，因此轻醒提供可选的进程防护。

## 用户选择与副作用

- 新安装默认关闭，已有的无确认版本配置也按关闭处理。
- 拉取代码、构建、复制应用和打开设置只提供功能，不自动安装或启动后台保护。
- 用户勾选开关后还需确认副作用；确认框默认按钮是“取消”。
- 只有确认后才保存 `enabled: true` 和当前 `consentVersion`，安装当前用户的后台任务。此后记住用户选择，登录后继续保护。
- 保护期间，电脑操作与屏幕历史记录暂停，请求可能超时。Codex 可能将屏幕历史转为停止状态；恢复进程不会自动恢复历史，用户需要在 Codex 设置中手动重新开启。轻醒不调用历史记录的开启接口。

双击“轻醒设置.app”，进入“防亮屏保护”页可以开关该功能。自动熄屏模式中的菜单项“轻醒设置（退出熄屏模式）…”会先取消倒计时和自动熄屏，再打开设置，方便正常阅读提示。

## 环境与安装路径

支持当前项目的 Apple silicon / macOS 26 构建环境。构建需要完整 Xcode 和 Python 3.10+；后台脚本仅使用标准库，兼容 Xcode 提供的 `/usr/bin/python3`（已使用 Python 3.9 验证）。运行机器也需要该解释器可用，不能只复制应用到未配置开发工具的 Mac 后假定后台保护可用。

用户确认开启后，资源和运行状态安装到：

```text
~/Library/Application Support/ScreenGuard/QuietDesktop/
  preferences.json
  quiet_service_guard.py
  quiet_desktop_check.py
  quiet-sky.mjs
  runtime/owned.json
  runtime/status.json
  runtime/events.jsonl
~/Library/LaunchAgents/local.xy.lightwake.quiet-desktop.plist
```

所有路径按当前用户生成，支持含空格的目录，不含开发者用户名或本机绝对路径。默认目标为 `~/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService`。使用自定义 Codex 数据目录时，需要在 LaunchAgent 的 `EnvironmentVariables` 中提供实际的 `CODEX_HOME`，再重新加载该任务；仅在 shell 配置该变量不会传给登录后台任务。

安装采用当前用户的 LaunchAgent，不需要管理员权限。应用和脚本不修改、重新签名或绕过 Codex 电脑操作服务的授权。

## 防护与恢复

状态检查只读取 CoreGraphics 显示器状态、当前会话及轻醒模式文件，不截图、不注入输入、不创建唤醒电源声明。

已启用时，后台程序每 250 毫秒检查一次。任意显示器睡眠、会话锁定或不在当前控制台、自动熄屏模式活动，以及状态无法确定，都按暂不可操作处理。只向当前用户、可执行文件路径完全匹配的目标服务发送 `SIGSTOP`。

暂停前先原子写入本程序的所有权记录，包含 PID、启动时间和可执行文件路径。原本已被其他工具暂停的进程不接管。正常亮屏、解锁且退出自动熄屏模式后，状态持续正常两秒，并在恢复前再检查一次，才向本程序暂停的进程发送 `SIGCONT`。PID 已被复用时不发信号。后台程序重启后使用记录继续清理，不会在退出时直接恢复全部服务。

取消勾选会保存关闭状态，停止申请新的暂停。仍有本程序暂停的服务时，会等正常使用电脑后恢复；记录清空后后台程序正常退出，LaunchAgent 不因正常退出反复重启。再次主动开启会重新启动它。没有同意配置、也没有待清理记录时，脚本直接退出，不扫描或控制进程。

这是有轮询间隔的本地缓解措施：新服务可能在被发现前创建声明，已有声明不会被撤销，显示器状态也可能在检查后变化。它不能保证拦住每次亮屏，也不能阻止其他应用、硬件或系统事件唤醒显示器。

## 任务调用检查

随包附带的 `quiet-sky.mjs` 可供使用 Sky 的任务主动检查桌面是否可操作。用户启用保护并安装资源后，任务可使用：

```js
var quietPath = (await import('node:path')).join(
  (await import('node:os')).homedir(),
  'Library/Application Support/ScreenGuard/QuietDesktop/quiet-sky.mjs'
);
var quietModule = await import((await import('node:url')).pathToFileURL(quietPath).href);
var sky = quietModule.createQuietSky((await import('@oai/sky')).sky);
```

每次原生桌面调用前都会检查。遇到 `DESKTOP_DEFERRED` 应继续代码、日志和构建工作，延后桌面验证，不换用未包装的客户端重试。包装器保留原客户端的授权流程。安装设置应用不会自动修改 Codex 的全局任务指令；原始 Computer Use 调用仍可能唤醒显示器。

## 关闭与移除

1. 在轻醒设置中取消勾选。若提示等待恢复，请在你需要使用电脑时正常亮屏、解锁并退出自动熄屏模式。无需为了移除立即亮屏。
2. 等状态显示已关闭且没有待恢复服务后，如需彻底移除后台文件，在终端执行：

```sh
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/local.xy.lightwake.quiet-desktop.plist"
rm "$HOME/Library/LaunchAgents/local.xy.lightwake.quiet-desktop.plist"
rm -r "$HOME/Library/Application Support/ScreenGuard/QuietDesktop"
```

最后一条只移除此功能的资源、偏好和日志。不要在仍提示等待恢复时删除所有权记录。关闭本功能也不会替你重开 Codex 屏幕历史。

## 验证范围

`python3 scripts/test.py` 验证默认关闭、取消、明确同意、安装失败回滚、路径可迁移、显示器和会话判定、真实独立测试进程的暂停与恢复、退出后清理、外部暂停与 PID 复用。测试不会操作真实的 Codex 服务，不显示设置窗口，也不会开启保护。

真实验收需要用户主动开启后，经历正常的熄屏、锁屏、解锁和退出自动熄屏模式；同时检查是否意外亮屏、服务是否恢复，以及屏幕历史状态。代码测试和签名验证不能代替这项体验验收。
