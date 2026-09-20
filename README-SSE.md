# FlClash SSE（Windows 隔离版）

在 FlClash 0.8.98 上增加模拟 SSE 链路测速，不调用模型，也不下载大文件测速。

## 使用

安装到独立目录，在本版导入、更新订阅，再点击节点页的闪电按钮。整批测试覆盖本版所有已缓存订阅，按连接配置去重，保留各订阅的节点名称。节点卡片可单独重测。

- 固定发送 161 个 256 字节事件，间隔 50 ms，持续 8 秒。
- **模拟 tok/s = 161 ÷ 从请求发起到完整结束的秒数**，包含握手与首段等待；不是模型 tokenizer 吞吐，也不是 Mbps 换算。
- 同时记录首事件延迟、抖动、额外停顿及攒包比例，必须收到完整序号和结束事件才产生有效成绩。
- 512 路并发，1 ms 启动间隔；内核整批预算 19 秒，界面请求截止 20 秒。不可达、源故障、超时及排队未开始分别显示，不能把它们当作全部测完成功。节点很多或握手很慢时，20 秒内不一定全有有效成绩。

**新的有效成绩到来前，旧 tok/s 始终保留**。测试中及失败状态与历史成绩分开，历史记录原子写入 `sse-history-v1.json`。配置指纹改变后视为新节点，不把同名旧节点的成绩套给新连接。

每次启动只从仍存在、历史流式质量达标的节点中选择最高模拟 tok/s 候选，恢复对应订阅和可手动选择的组，不为选节点重新测速；无候选则保持原选择。自动策略组仍按原规则工作。

## 隔离

- 应用、内核和辅助服务分别为 `FlClashSSE.exe`、`FlClashSSECore.exe`、`FlClashSSEHelperService.exe`。
- 独立安装标识和产品数据目录（`lop-spec/FlClashSSE`）；只注册 `flclashsse://`。
- 代理默认端口 17896，辅助服务端口 47896。默认关闭系统代理和自动系统 DNS。
- 安装器不按进程名结束程序、不注销原版服务，并拒绝覆盖存在 `FlClash.exe` 的目录。
- 测速通过每个节点独立连接，不切换当前 selector、不启动 TUN、不清理日常连接。

HTTP/file provider 使用本版缓存，支持常规筛选、前后缀及连接参数覆写。缓存缺失、表达式/正则重命名覆写及 `dialer-proxy` 链式依赖会明确报告，不悄悄改成直连。需要先更新订阅；脚本生成但未落入缓存的节点不在静态目录中。

## 开发验证

发布安装包只通过 `.github/workflows/build.yaml` 云端生成。源码继承 FlClash GPL-3.0；帧与节奏协议参考 Stream Quality，MIT 许可保留于 `sse-source/STREAM-QUALITY-LICENSE`。

```sh
cd core
go test -count=1 -v . ./ssebench
go vet . ./ssebench
go run ./cmd/ssecheck -count 8
cd ..
node --test sse-source/worker.test.mjs
flutter test test/common/sse_history_test.dart
```

`Test1024RealStreamsWithin20Seconds` 使用 1024 条真实本地 HTTP SSE 连接，而非空任务计时。`ssecheck` 只请求独立模拟源。服务端源码为 `sse-source/worker.mjs`，协议标识为 `fc-sse-v1-256b-50ms-8s`；与旧 20 秒 Stream Quality 源不混用。
