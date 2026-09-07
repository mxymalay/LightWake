# Codex 请求入口保护补丁

状态：**候选代码，尚未安装或启用。** 目标是修改 Codex 发出原生桌面请求的地方，避免请求进入电脑操作服务后创建亮屏声明。不是修改系统电源策略，也不暂停或终止进程。

已核对当前安装包为 Codex 26.901.41600 / build 7982。其 JavaScript worker 的原生传输入口供截图、状态查询和记录控制等请求共用；主程序另有服务获取与重新启动入口。补丁在这两个入口检查显示器、会话及轻醒模式，在异步初始化原生运行库后再次检查。拒绝时返回 `DESKTOP_DEFERRED`，不保存请求等待解锁后重放，不伪造截图、成功结果或授权。

`lightwake-request-guard.cjs` 是新增模块。只有单独的用户选择明确开启时才检查；缺少选择文件时完全不介入，不写配置。原调用中的权限验证、请求类型、参数、超时和目标进程保持原样。此候选模块没有安装、启用或签名命令，不迁移旧版服务冻结的开启选择。

## 无界面验证

在仓库根目录运行以下命令。准备脚本只读取已安装的 Codex，将修改后的代码和基线副本写入忽略的构建目录，不修改 `.app`，也不启动应用。版本或代码结构不同会拒绝处理；已有输出目录不会覆盖。

```sh
python3 integrations/codex-request-guard/prepare.py
node --test integrations/codex-request-guard/test-policy.cjs
node integrations/codex-request-guard/test-transport.cjs .build/codex-request-guard
node --check .build/codex-request-guard/worker.js
node --check .build/codex-request-guard/main-C5K7o1Hr.js
```

使用 `--codex-app` 指定其他安装目录，使用 `--output` 选择新的输出目录。不会修改用户的 Codex 设置或开启屏幕历史。

对原始代码运行传输测试，可验证缺少拦截时测试确实失败：

```sh
node integrations/codex-request-guard/test-transport.cjs .build/codex-request-guard/baseline
```

基线的 8 项拒绝预期失败，修改后的 10 项传输检查通过；另外 14 项策略检查覆盖默认关闭、主动关闭、锁定、多屏、状态不明、损坏设置及每次重新检查。测试执行从实际安装包提取的调用函数，但替换最后的原生边界，不发送 Apple Events，不触发桌面操作。这不等于整套 Codex 的真实运行验收。

## 部署仍待解决

安装包的 `Info.plist` 有 `ElectronAsarIntegrity`，签名也覆盖应用资源。电脑操作服务接收请求时校验发送方的签名团队身份。直接改 `app.asar` 会破坏原有完整性；随意重新签名可能破坏服务通信、钥匙串及其他权限。该补丁没有删除完整性或发送方身份检查，也没有加入新的可信签名者。

因此当前输出不能当作可直接替换的正式应用。需要在保持原授权机制的可用发行构建中集成，或先取得可验证的本地签名兼容方案；不能把普通 JavaScript 测试通过当作解决了签名问题。当前软件里的“防亮屏保护”尚未重新开放。

此外，还需验证已有原生采集任务、独立运行的历史记录及其他未经过这两个入口的服务客户端。此补丁阻止新请求，不会回收已经创建的亮屏声明；状态检查与实际请求之间也仍有很小的竞争窗口。正式实现最好在服务创建亮屏声明之前再做一次同样的检查，并让后台状态请求本身无需唤醒。

最终启用仍须用户明确选择，并在真实锁屏、密码、指纹、普通按键和指定映射键上验收。不会为测试重放用户输入、自动解锁或启动记录。
