# 架构说明

LightWake 包含两个独立模块：`apps/screen-guard` 负责熄屏和提示，`apps/system-widget` 负责系统采样与原生小组件。两者不依赖对方常驻运行。

## 屏幕工具

同一份 AppKit 程序打包为“关闭屏幕”和“开启屏幕”，由各自 `Info.plist` 中的 `ScreenGuardRole` 选择入口。

| 文件 | 职责 |
| --- | --- |
| `GuardState.swift` | 纯状态机，接收单调时钟时间与屏幕睡眠 / 唤醒事件，输出提示、数字倒计时、熄屏等阶段。 |
| `ScreenGuard.swift` | 控制器、提示窗口、收起动画、菜单栏入口、电源声明和系统事件监听。 |
| `ControlStore.swift` | 用模式令牌和跨进程文件锁协调开启 / 关闭操作。 |
| `Main.swift` | 两种应用角色的启动与重复打开行为。 |

### 计时与取消

双击“关闭屏幕”启动 5 秒窗口：前 3 秒显示提示，随后平移缩小到每块屏幕可见区域的左上角，余下 2 秒显示数字。动画不会额外增加总时长。

只有收到真实的 `screensDidSleepNotification` 后，下一次 `screensDidWakeNotification` 才会启动新的 20 秒窗口。前 3 秒显示提醒，随后 17 秒显示角落数字；轮询、重复唤醒通知不会重置起点。计时使用 `systemUptime`，避免系统日期变化影响倒计时。

控制器在主线程处理计时与动作。到期通过 `/usr/bin/pmset displaysleepnow` 请求显示器睡眠；在尚未收到睡眠通知时，状态机会间隔 20 秒重试，不因延迟的计时回调连续发出命令。

运行中的关闭工具持有 `PreventUserIdleSystemSleep` 电源声明，允许显示器关闭，同时阻止闲置触发整机睡眠。停止时释放声明；这不改变系统持久电源设置，也不替代系统的锁屏策略。

“开启屏幕”先将本机模式文件写为 `off`，再发送分布式停止通知，并以短时 `caffeinate -u` 请求亮屏。模式令牌是最终依据：关闭工具会在每次执行前检查令牌，并通过同一把 `flock` 将最后一次检查和实际关屏命令串行化。取消写入完成后，旧令牌不能再触发关屏。运行状态位于当前用户的 `Application Support/ScreenGuard` 目录。

提示是独立的 AppKit 非激活窗口，忽略鼠标点击，避免夺取当前应用焦点；角落数字是桌面窗口，不是菜单栏倒计时。系统锁屏界面不属于这些窗口的显示范围。

## 系统状态小组件

`HostApp.swift` 提供设置说明和预览；`WidgetExtension.swift` 注册 WidgetKit 扩展及三个样式。中号支持详细横排和简洁横排，大号支持详细布局与竖排。`WidgetUI.swift` 与 `SimpleWidgetUI.swift` 共用数据模型及刷新意图。

每次采样流程为：

1. 获取 CPU 计数基线，等待约 350 毫秒，再获取 CPU 与内存样本。
2. 读取电源、电池和当前用户主目录所在卷的容量。
3. 生成带采样时间的 `DashboardEntry`。
4. Timeline 请求约 15 分钟后的下一次刷新，实际执行由 macOS 决定。

右上角刷新按钮执行 `RefreshMetricsIntent`，通知 WidgetKit 重新加载时间线。预览按钮也会重新采样并发出刷新请求。

### 指标边界

- `SystemMetrics.swift` 读取 Mach 系统计数，按增量计算全机 CPU 使用率。内存使用量按页数计算，包含压缩内存的物理占用，避免将压缩前的大小重复累加。
- `PowerDiskMetrics.swift` 解析 IOKit 电源信息。输入遥测单位是推断值，必须通过电压与电流的乘积校验，并保留“估算”标记；无法验证时不显示输入功率。
- 电池剩余时间来自系统 `Time to Empty`，仅用于电池供电且未充电的状态。未知时间和无效值不换算为续航；不会将百分比电量误当作毫安时计算。
- 磁盘使用普通卷容量 API，已用量为总量减可用量。采样不遍历用户文件。
- 电源读取只保留指标所需字段，不读取或记录完整电池注册表对象。有效性检查失败的单项以空值进入界面。

### 打包与平台适配

宿主应用内嵌 `SystemStatusWidget.appex`，两者启用应用沙箱。构建使用 Swift 编译器和 App Intents 元数据工具，并为扩展设置 `_NSExtensionMain` 启动入口；宿主普通可执行入口不能代替该入口。

简洁横排使用 macOS 26 上已存在但未公开声明的 WidgetKit 原生模糊背景接口。`prepare_widgetkit_overlay.py` 检查所需链接符号，从当前 SDK 生成本地编译适配目录，并补充接口声明。产物仅位于 `apps/system-widget/build/compiler-overlays`；不修改已安装 SDK，不在应用中嵌入替代 WidgetKit，也不提交 SDK 副本。系统或 SDK 变化时需要重新验证，脚本遇到不匹配会中止构建。

应用包采用本机临时签名，用于自行构建和本机安装；当前流程不包含 Developer ID 公证或 App Store 分发。

## 验证范围

根目录的 `scripts/test.py` 汇总计时状态、模式存储、控制器集成、系统采样与电源 / 磁盘解析检查。集成检查通过可替换的时钟、提示和关屏动作验证行为，不实际执行关屏。`--visual` 额外运行真实提示窗口和动画检查。

这些检查覆盖代码路径，不能代替不同 macOS 版本、硬件和通知中心图库上的实际安装验证。`scripts/build.py` 构建两个模块，并检查生成应用的签名。
