# FlClash SSE（Windows 隔离版）

在 FlClash 0.8.98 上为 ChatGPT 和 Claude 给节点打分：不调用模型，不下载大文件，只看节点能不能用、离源站多近、空闲连接能撑多久。

## 使用

安装到独立目录，在本版导入、更新订阅，再点击代理页的「全部测速」。测速始终在后台运行，不弹窗口、不锁住页面，离开页面也继续执行。整批覆盖本版所有已缓存订阅，按连接配置去重，保留各订阅的节点名称。节点行右侧可单独重测（只做初筛，不参加淘汰赛、不加分）。

代理页顶部常驻显示当前选择的订阅和节点；所有订阅分组默认折叠，点击组头展开或收起。展开后是紧凑单行小格，悬停可看得分、延迟、出口机房、淘汰赛名次和最新失败原因。各订阅内按累计得分降序，同分按最近一次延迟升序，未测速节点置后。

## 测速流程

1. **初筛**（约 15–30 秒）：每个节点同时连 `chatgpt.com` 和 `api.anthropic.com`，只认未登录的 401；403（地区封锁或 Cloudflare 拦截）标为拒绝，两边任一不通都不参加后续比赛。ChatGPT 连接上顺序连发 5 次请求，取最小值为节点延迟，出口机房取自 `Cf-Ray`。32 路并发，30 秒截止。
2. **机房统计**：按出口机房汇总，机房延迟取其节点延迟的中位数，选出最快的两个机房。
3. **淘汰赛**（通常 1–3 分钟，最长 15 分钟）：两个机房的所有节点保留初筛那条 ChatGPT 连接，统一发一次请求后进入空闲。中继空闲超时会用 FIN/RST 关闭连接，被动记录谁先断，不发任何会重置空闲计时的数据。先断的先淘汰，直到剩最后一个。5 秒内先后断掉视为平手，按延迟排先后；最后一名幸存者要比上一个断线者多撑 5 秒才算独胜。
4. **计分**：前四名依次加 4、3、2、1 分，按节点配置指纹累计写入 `node-score-v1.json`。配置指纹改变视为新节点，不继承旧分。最近一次失败会覆盖延迟显示，但不扣分。

## 自动切换

- **重启**：从仍存在、未被拒绝的节点中切到得分最高者，恢复对应订阅和选择路径，不为选节点重新测速；没有得分则保持原选择。
- **实时故障切换**：监控真实流量的日志，出现连接层失败就切到排名下一位（到末尾回到第一），60 秒冷却，启动后第一分钟不切。
  - Claude：`%USERPROFILE%\.claude\projects` 下会话记录里的 `api_error`，只认 ECONNRESET、ETIMEDOUT 等连接错误和请求超时；ConnectionRefused（本机代理端口没开）和 HTTP 状态错误（429、529 等）不算。
  - ChatGPT：pi-web GPT 桥日志 `%LOCALAPPDATA%\pi-web\portable\data\codex-responses-proxy.log` 里经本版代理端口的「连接层失败」。桥要把出口指向本版的混合端口才有意义。
- 每次切换和因冷却未切换都写入应用日志。

## 隔离

- 应用、内核和辅助服务分别为 `FlClashSSE.exe`、`FlClashSSECore.exe`、`FlClashSSEHelperService.exe`。
- 独立安装标识和产品数据目录（`lop-spec/FlClashSSE`）；只注册 `flclashsse://`。
- 代理默认端口 17896，辅助服务端口 47896。默认关闭系统代理和自动系统 DNS。
- 安装器不按进程名结束程序、不注销原版服务，并拒绝覆盖存在 `FlClash.exe` 的目录。
- 测速通过每个节点独立连接，不切换当前 selector、不启动 TUN、不清理日常连接。

HTTP/file provider 使用本版缓存，支持常规筛选、前后缀及连接参数覆写。缓存缺失、表达式/正则重命名覆写及 `dialer-proxy` 链式依赖会明确报告，不悄悄改成直连。需要先更新订阅；脚本生成但未落入缓存的节点不在静态目录中。

## 开发验证

发布安装包只通过 `.github/workflows/build.yaml` 云端生成。源码继承 FlClash GPL-3.0。

```sh
cd core
go test -count=1 -v . ./ssebench
go vet . ./ssebench
# 用已安装版的订阅副本跑完整初筛和淘汰赛（不写真实数据）
FLCLASH_SSE_LIVE_HOME=<应用数据目录> FLCLASH_SSE_LIVE_OUT=<结果.json> go test -count=1 -timeout 20m -run TestLiveBatchAndTournament -v .
cd ..
flutter test test/common/sse_history_test.dart test/common/sse_failover_test.dart test/providers/sse_startup_test.dart test/views/sse_dialog_test.dart
```

`TestFullScreenOf256NodesWithinBudget` 用 256 条真实本地 TLS HTTP/2 连接验证初筛预算；`tool/sse-smoke.cjs` 对安装后的内核跑一遍初筛、限时淘汰赛、重启恢复和失败保分。
