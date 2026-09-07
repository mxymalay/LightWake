# Codex 防亮屏检查与旧版保护停用

## 当前状态：2.5.2

直接暂停电脑操作服务的保护方式已经撤下，设置中不能重新开启。实测中出现指纹匹配成功后登录界面卡住、需要强制重启；同一时段系统记录被暂停的服务无响应。现有日志不能证明完整因果链，当前版本先停止这条机制，不能将构建和模拟测试描述为已通过真实解锁验收。

新版本启动时关闭旧版的开启选择，不安装或启动新的保护任务，不发出进程恢复、亮屏或认证命令。旧版未更新的后台脚本读取关闭选择后不再获取新的暂停。新版脚本即使读到旧的 `enabled: true` 配置也不会冻结进程，信号边界拒绝 `SIGSTOP`。HOME 等按键规则、目标应用及项目文件夹仍独立工作。

设置页保留停用说明和旧版关闭入口。轻醒不会自动解锁、存储密码或自动开启屏幕历史记录。

## 保留的任务调用检查

随设置应用打包的 `quiet_desktop_check.py` 和 `quiet-sky.mjs` 只读取显示器、会话和轻醒模式状态，不截图、不注入输入、不创建唤醒声明、不暂停其他进程。

需要使用 Sky 的任务可主动采用包装器；将路径指向当前安装的设置应用资源：

```js
var quietModule = await import('file:///Applications/轻醒设置.app/Contents/Resources/quiet-desktop/quiet-sky.mjs');
var sky = quietModule.createQuietSky((await import('@oai/sky')).sky);
```

如果应用安装在其他目录，请调整路径。每次原生桌面调用前都会重新检查，遇到 `DESKTOP_DEFERRED` 时继续代码、日志、构建等后台工作，延后桌面验证，不换用未包装的客户端重试。包装器保留原客户端的授权流程。

这只是任务调用前的状态快照，检查后显示器状态仍可能改变，也无法拦截 Codex 主程序直接发给电脑操作服务的请求。不能声称原始 Computer Use 调用不会亮屏，或可以保证阻止所有来源的亮屏。应用不会自动修改 Codex 的任务指令。

## 旧版状态与移除

旧版使用以下用户目录：

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

新脚本只保留旧暂停记录的清理能力。确认亮屏、已正常解锁、退出自动熄屏模式且状态稳定后，校验可执行文件、用户、PID 和启动时间，只恢复自身记录的进程。不存在、已换用或由其他工具暂停的进程不恢复。仍锁定或状态未知时保留记录；不要在解锁卡住时继续反复测试，也不要删除尚有待恢复进程的记录。

更新应用后启动“轻醒设置”，确认旧保护已关闭。若仍显示待恢复服务，应先处理旧服务状态；在记录为空时，可移除已退出的登录任务：

```sh
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/local.xy.lightwake.quiet-desktop.plist"
rm "$HOME/Library/LaunchAgents/local.xy.lightwake.quiet-desktop.plist"
```

日志和脚本可保留用于排查。不要在未确认暂停记录为空时删除整个目录。关闭此功能不恢复 Codex 屏幕历史；如果需要历史记录，仍由用户在 Codex 中自行开启。

## 验证

`python3 scripts/test.py` 覆盖拒绝重新开启、旧开启配置不能冻结服务、无状态时退出、设置开关不可开启，以及旧暂停记录的安全清理。测试只用临时目录、模拟会话及独立 C 测试进程，不操作真实 Codex 服务，不触发锁屏或指纹验证。

实际锁屏兼容性仍需在用户决定继续正常使用时验证。修复期间不自动锁屏、唤醒、重启或重开这条已停用的机制。
