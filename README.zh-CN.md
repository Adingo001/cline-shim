# cline-shim

[English](README.md) | **简体中文**

一个本地的 OpenAI 兼容适配器，前置在 Cline Pass 订阅网关之前。它监听
`127.0.0.1:8788`，修复四处会让普通客户端出错的 wire 细节，并把上游 channel
钉住，免得一次请求随机落到慢的服务器上。

它是为 [dsh](https://github.com/deepseek-ai) 做的 —— 那个 harness 在
`settings.yaml` 里把 `cline` provider 指向这里并且没有 fallback —— 但它与调用方
无关：任何说 OpenAI wire 的客户端都能用。其它消费者的说明在
[`docs/`](docs/) 下：[OpenAI4S](docs/openai4s.md)、
[Claude Code](docs/claude-code.md)。

## 适用范围

它是什么：

- **仅监听回环地址**的适配器。只绑 `127.0.0.1`，原样转发调用方自己的
  `Authorization` 头，本身不存任何凭证。
- **wire 规范化层**：响应信封、reasoning 字段名、裸模型 id、瞬时路由失败。
- **channel 钉选**：由它指定推理 channel，而不是让路由器每次现挑。

它不是什么：

- 不是代理，也不是共享服务。它不是给别的机器用的网关，仓库里没有任何东西是照着
  "被本机之外的地址访问"设计的。
- 不是绕过计费的手段。它不携带 key，每个请求都记在调用方自己 key 所属的账号上。
  钉 channel 改变的是哪台服务器应答，从来不是谁付钱。
- 不是 Cline 账号工具。它需要你本来就有一个可用的订阅 key；除了把它透传给上游，
  它不获取、不轮换、也不额外校验 key。
- 不再是 OpenAI4S 或 Claude Code 的安装器。驱动那两套安装的启动器已经从本仓库
  拆出去了 —— 见 [docs](docs/)。

## 安装会改什么

`install-autostart.ps1` 是唯一的入口。运行它会改动的东西只有这些：

| 位置 | 内容 | 为什么 |
| --- | --- | --- |
| `$HOME/openai4s-shim/`（WSL 内） | `shim.py`、`ctl.sh`、`autostart.sh`、`_verify.sh`、`_diag.sh`、`_heal_test.sh` | 适配器和它的检查脚本；经 `\\wsl.localhost` 复制过去，然后统一行尾、加执行位 |
| `/etc/systemd/system/cline-shim.service` | 一个 systemd unit，`Restart=always`、`RestartSec=5`、开机启用 | 它负责 shim 进程；通过 `wsl -u root` 写入 |
| Windows 计划任务 | 名为 `Cline shim` 的任务，登录触发，以当前用户身份运行，命令是 `wsl.exe -d Ubuntu -- sleep infinity` | 它负责保住 WSL2 虚拟机 —— 否则最后一个 `wsl.exe` 客户端断开约 60 秒后 VM 就被拆掉 |

它**不**碰注册表、`PATH`、驱动，也不碰 Task Scheduler 之外的任何 Windows 文件。
它不安装 Python 包。`-ExecutionPolicy Bypass` 只作用于那一个 PowerShell 进程，
不是整机设置。

运行前有两点值得知道：

- 写 unit 和启用开机自启需要 root。`install-autostart.ps1` 走 `wsl -u root`
  而不是 `sudo`，所以不会弹密码提示。
- 任务是以空密码注册的，所以 `schtasks` 会警告它"可能因安全策略而无法运行"。
  手动触发返回 `LastResult: 0`；但登录触发到底会不会自己点火，还没有经过一次
  真实重启确认。如果重启后 shim 没起来，手动启动任务并用 `_diag.sh` 看状态 ——
  这是**结论没验证**，不等于安装坏了。

## 安装

```powershell
powershell -ExecutionPolicy Bypass -File install-autostart.ps1
```

可选参数：`-Distro Ubuntu`、`-TaskName 'Cline shim'`、`-InstallRoot <路径>`。
安装根目录默认是发行版内的 `$HOME/openai4s-shim` —— 这是历史遗留的名字，现有
安装都指着它。shim 本身与 OpenAI4S 没有依赖关系。

然后把 dsh 指过来，在 `settings.yaml` 里：

```yaml
llm-pi-ai:
  providers:
    cline:
      baseURL: http://127.0.0.1:8788
```

## 如何卸载

```powershell
powershell -ExecutionPolicy Bypass -File install-autostart.ps1 -Remove
```

它会停止并注销任务、停用并删除 unit、执行 `systemctl daemon-reload`。它有意
保留磁盘上的 `$HOME/openai4s-shim/`，好让你的日志留下来；想彻底清掉就自己删。

如果 `-Remove` 失败 —— 通常是任务已被手工删掉，或者发行版没在运行 —— 分两层
单独处理：

```powershell
Unregister-ScheduledTask -TaskName 'Cline shim' -Confirm:$false
wsl -u root -d Ubuntu -- bash -lc "systemctl disable --now cline-shim.service; rm -f /etc/systemd/system/cline-shim.service; systemctl daemon-reload"
```

只删任务**不会**停掉 shim：任务负责 VM，systemd 负责进程。停 shim 用
`ctl.sh stop`。

## 没有 shim 会怎样

| 消费者 | 配置位置 | 没有 shim 时 |
| --- | --- | --- |
| dsh（`settings.yaml`） | `baseURL: http://127.0.0.1:8788` | 没有 fallback。每一轮都失败在 `fetch failed` / `ECONNREFUSED`，dsh 的分类器把它归为 `TRANSPORT`，于是退避重试 5 次，最后报一个传输错误。 |

## 为什么需要这一层 shim

`https://api.cline.bot/api/v1` 说的是 OpenAI wire，但有四处细节会让普通客户端
出错：

1. 非流式响应被包在 `{"data": {...}, "success": true}` 里，直接取
   `body["choices"]` 的阻塞式路径会抛 `KeyError`。
2. 推理内容以 `reasoning` / `reasoning_details` 下发，而 OpenAI 的约定是
   `reasoning_content`。
3. 模型 id 必须是 `cline-pass/<name>`。裸的 `z-ai/<name>` 会走 Cline Credits
   而不是订阅，返回 HTTP 402。
4. 路由未命中表现为 HTTP 500 `empty response content`，值得透明重试一次。
5. 网关自动挑的 channel 既不是最稳的也不是最快的，而未命中要赔上整轮。

`shim.py` 在 `127.0.0.1:8788` 上把这五点全部修掉，不去 patch 任何客户端。它只用
标准库，原样转发调用方的 `Authorization`，不存凭证。

裸模型名（`glm-5.3`）和上游目录 id（`z-ai/glm-5.3`）都会被规范成
`cline-pass/glm-5.3`。

## 上游 channel 钉选

一个 Cline Pass 模型不是由一台机器服务的。网关会把它路由到大约十五个推理
channel 上，拿到哪一个按请求决定。2026-09-17 在 `cline-pass/deepseek-v4.1-flash`
上实测：路由器自己挑的每次都答对，但散布在它喜欢的任意 channel 上（8 轮里
`fireworks:4 alibaba:3 novita:1`），而且那个池子里有些 channel 要一分钟才吐出
第一个 token。shim 通过自己指定 channel 来消除这种抽签：同一组测量，均值 1.4s
而不是 2.5s，并且永远是同一台服务器。

### wire 格式

网关从 `providerOptions.gateway` 读钉选信息：

| 字段 | 含义 |
| --- | --- |
| `only` | 白名单 —— 路由器必须用其中之一，否则失败 |
| `order` | 偏好顺序 —— 先试这些，再试其余的 |
| `sort` | `cost` \| `ttft` \| `tps` —— 按某个指标选胜者 |

OpenRouter 的写法（`provider.only` / `provider.order`）会被接受但静默忽略：
在两种写法下各钉一个不可能的 provider 名字，只有 `providerOptions.gateway` 这种
让路由器发出了抱怨。`sort` 也没法折进 `order` 的列表 —— 这个网关对 `order` 里
未知 provider 名字是**拒绝**而不是降权，所以一个没验证过的名字是硬失败，不是
fallback。

### 两条规则

- **只在第一个 token 之前允许 failover。** 内容一旦到达调用方，这次回复就归他了；
  重发等于重复输出。流式 wire 上的路由未命中**不是** HTTP 错误 —— 网关会回
  `200 text/event-stream`，而它的第一帧就是
  `{"error":{"code":"stream_initialization_failed",...}}`。所以 shim 会把帧压住，
  直到某一帧带内容，这时才提交 200。一条结束却没有内容的流会变成
  `EMPTY_RESPONSE`。
- **死 key 和欠费墙永不重试。** 所有 channel 都在同一个账号后面，换着试只是把
  同一个失败重演一遍。其它情况 —— 路由未命中、channel 满载、流中断 —— 都是
  channel 相关的，正是下一次尝试该做的。

### 默认值

`cline-pass/deepseek-v4.1-flash` 的内置顺序是 `togetherai, novita, deepinfra,
parasail, alibaba, runware, boundless, gmicloud`：测量时干净应答的那个子集，按
观测到的首 token 时延排序。其余 channel 不是因为坏了才被排除 —— 容量一天之内就
会变（`fireworks` 早上满载，晚上却服务了 8 次未钉选请求里的 4 次）—— 但钉选只有
稳定才划算，所以顺序里列的是既快又持续在线的服务器。

### 配置

| 变量 | 默认 | 含义 |
| --- | --- | --- |
| `CLINE_SHIM_PIN_MODE` | `strict`（经 `ctl.sh`） | `strict` \| `preferred` \| `off` |
| `CLINE_SHIM_PIN` | *（内置）* | 逗号分隔的 channel 顺序；**完整替换**内置列表 |
| `CLINE_SHIM_EXCLUDE` | *（无）* | 要绕开的 channel |
| `CLINE_SHIM_BUDGET` | `120` | 花在 failover 上的秒数，不含生成 |

`preferred` 用 `order` 走列表，所以路由器仍可能落到没验证过的 channel。
`strict` 用 `only` 逐个钉住 channel —— 这是唯一能强制某个冷门 channel 的办法，
代价是死掉的 channel 会在一次尝试内变成硬失败，然后 shim 才移到下一项。`off`
恢复成纯透传。

各 8 轮流式测量：`off` 8/8、均值 2.5s，`strict` 8/8、单 channel 均值 1.4s，
`preferred` 7/8（有一次空响应，来自路由器落到的那个 channel）。`off` **没有**
坏；钉选的理由是 dsh 的一轮很长，所以首 token 才是贵的那部分，稳定的 1.4s 胜过
波动的 1.5–4s。

### 怎么观察

| 路由 | 用途 |
| --- | --- |
| `GET /health` | 存活、pin 模式、排除列表 |
| `GET /models` | 订阅可用的模型 id |
| `GET /channels?model=<id>` | 某个模型解析出的尝试顺序 |

`/channels` 默认返回内置顺序。加上 `&discover=1` 会花一次请求（不消耗 token ——
路由器在生成前就失败了）让网关自己报出它的 channel，并把结果缓存一小时。

## shim 跑在哪里

`shim.py` 本身没有任何 POSIX 依赖。它 import 的是 `json`、`os`、`re`、`sys`、
`time`、`urllib` 和 `http.server`，`main()` 就是一个绑在 `127.0.0.1` 上的
`ThreadingHTTPServer`。它在 Windows、发行版内、Linux 主机上都原样能跑。

因为它只绑回环，**每个消费者都需要各自通往它的路径**。决定部署形态的是这条
路径，而不是 shim 本身：

| shim 跑在 | dsh 怎么到达 | OpenAI4S 怎么到达 |
| --- | --- | --- |
| Windows 上 | 直连 —— `local-shim.ps1` 搭的就是这条 | 需要 SSH 隧道，否则到不了 |
| Linux 中转服务器 | Windows 侧的 SSH 隧道 | 发行版内部的 SSH 隧道 |
| 发行版内 | 经 WSL2 的 localhost 转发 | 同一发行版内，直连 |

**dsh 走的是第一行。** 它是个 Windows 应用，而 `shim.py` 只用标准库，所以中转
服务器和 SSH 隧道对 dsh 从来就不是必需的 —— 那套东西是从围绕 OpenAI4S 的部署里
继承下来的。`local-shim.ps1` 把 shim 常驻在本地，`dsh.ps1` 在打开应用前调它，
因此登录时什么都不用跑。

之所以留着 shim 而不是让 dsh 直连网关：钉住上游渠道、以及渠道返回空响应时的
故障转移，都是 shim 在做。实测有一轮是 `[togetherai!] empty -> next channel`，
1.9 秒后由 novita 服务。直连没有这种恢复能力。

之所以还需要一个发行版，是因为 **OpenAI4S** 要求 Linux
（`start_new_session=True`、带精确 `SIGINT` 的 per-cell 进程组、bubblewrap
沙箱后端），**不是**因为 shim 要求。如今 OpenAI4S 是 WSL 这一层存在的唯一理由。

只绑回环不是附带选择。绑到 `0.0.0.0` 的 shim 就是一个开放中继 —— 局域网里
任何自带 key 的人都能用。

## 把 shim 放到中转服务器上

`shim.py` 并不绑定 WSL。在一台 Linux 中转服务器上，它只需要一个文件加一个
systemd unit —— 没有 VM 保活任务，没有 `wsl -u root`，也没有那个 30 秒循环，
因为那边的 systemd 是原生的：

```ini
[Unit]
Description=Cline shim (pinned Cline Pass adapter on 127.0.0.1:8788)
# 只绑回环：刻意不加 network-online.target，它在 DNS/路由不健康时会让 unit 无限阻塞。

[Service]
Type=simple
WorkingDirectory=/opt/cline-shim
Environment=CLINE_SHIM_PIN_MODE=strict
ExecStart=/usr/bin/python3 /opt/cline-shim/shim.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

shim 只绑回环，所以从别的机器访问它必须走隧道。`tunnel-shim.ps1` 负责维持这条
隧道，健康检查失败就重建；它带一个按端口加锁的互斥量，避免启动项和手动运行去
抢同一个本地端口：

```powershell
$env:CLINE_TUNNEL_SERVER = '<中转服务器地址>'
Start-Process powershell -ArgumentList '-NoProfile','-WindowStyle','Hidden',
  '-ExecutionPolicy','Bypass','-File','D:\project\cline-shim\tunnel-shim.ps1' -WindowStyle Hidden
```

`CLINE_TUNNEL_SERVER` 没有默认值：中转服务器地址是部署相关的东西，而这个仓库是公开的。
其余用 `CLINE_TUNNEL_USER`（默认 `root`）、`CLINE_TUNNEL_LPORT`（默认 `8789`）、
`CLINE_TUNNEL_RPORT`（默认 `8788`）覆盖。

同一个 prompt、每条路 5 轮、交错执行的实测结果（交错是为了不让上游随时间的
波动算到恰好跑在坏窗口的那条路上）：

| 路径 | ttfb 中位 | ttfb 范围 | total 中位 | tps |
| --- | --- | --- | --- | --- |
| 本地 WSL shim（8788） | **1.22s** | 1.04–1.45s | **3.32s** | 83.9 |
| 隧道连中转 shim（8789） | 1.79s | 1.14–2.14s | 3.64s | 113.6 |
| 直连（无 shim） | 2.16s | 1.75–3.19s | 6.01s | **45.4** |

两条 shim 路径在**每一轮**都赢直连。直连那条路更大的离散度（ttfb 1.75–3.19s，
其中一轮 11.73s）正是没有 pin 的样子：网关每个请求各自挑 channel，有些挑得很差。

**路径约定。** shim 的 `CLINE_UPSTREAM` 已经带 `/v1`，所以调用方**不能**自己再加
这个前缀。往 `/v1/chat/completions` 发请求，等于让上游收到
`/api/v1/v1/chat/completions`，会在每一个 channel 上返回 404 —— 而 shim 会尽职地
把八个 channel 全部轮一遍才放弃。

## 怎么让它一直活着

两个事实让"启动一下就行"不成立：

1. dsh 在 `settings.yaml` 里把 `cline` provider 指向
   `http://127.0.0.1:8788`，没有 fallback，所以 shim 停了就是 dsh 完全答不了。
2. shim 跑在 WSL2 虚拟机里，而 WSL2 在最后一个 `wsl.exe` 客户端断开约 60 秒后
   会拆掉整个 VM —— 把 shim 一起带走。

三层覆盖这件事，每层只负责一种失效：

| 层 | 负责 | 机制 |
| --- | --- | --- |
| `Cline shim` 计划任务 | VM | 常驻 `wsl.exe -d Ubuntu -- sleep infinity`，让客户端一直挂着，VM 就不会空转退出 |
| `cline-shim.service`（systemd） | shim 进程 | `Restart=always`、5s —— 实测被杀后 3s 回来 |
| `autostart.sh` | 端口 | 调 `ctl.sh start`，然后每 30 秒复查一次（幂等 —— 端口还占用时 `ctl.sh` 直接返回） |

这个分工是有原因的。`autostart.sh` 是个循环，这也是它当初顺便扛住 VM 的原因 ——
那时任务直接跑它。但那让任务成了 shim 的第二个管理者，每次任务启动都会在 systemd
的旁边多留一个 supervisor。现在任务只管 VM，systemd 管 shim，恰好一个 supervisor。

不放开机启动：WSL 发行版是按用户分的，SYSTEM 任务根本看不见这个发行版。
也不放"启动"文件夹 —— `Start-Process` 出来的子进程会随启动它的 shell 一起被拆掉，
那等于移除了最后一个挂着的客户端，让 VM 空转退出。改由 Task Scheduler 持有
`wsl.exe` 客户端，它就比用户开的任何 shell 都活得久。

### 两个坑

都是搭建时真踩过的，表现都是"shim 没起来"。

**别让 unit 依赖网络。** `After=network-online.target` 看着无害，其实不是：网络
不通时这个 target 永远不会 active，unit 就一直等它，shim 永远不启动 —— 即使它
只监听回环、绑端口根本不需要网络。断网实测：`network-online.target` inactive，
service `active`，`/health` 正常。

**别给任务一次性命令。** 把它改成 `wsl.exe -d Ubuntu -- true` 会移除常驻客户端，
于是 VM 约一分钟后空转退出，把 shim 带走。任务必须留一个进程活着，
`sleep infinity` 是最小形式。

### 验证

```powershell
wsl -d Ubuntu -- bash -lc 'bash ~/openai4s-shim/_verify.sh'
```

关键是 `boot_id`：`boot_id` 不变而 `uptime` 增长，说明 VM 一直没重启；`boot_id`
变了，说明它重启过，任务的常驻客户端没起作用。完整测过一遍：`wsl --shutdown`
之后再由任务自己的命令拉起 —— 新的 `boot_id`、service `active`、shim 在监听、
`/health` 正常、只有一个 supervisor。

出问题时 `_diag.sh` 会 dump unit 状态、阻塞依赖和两份日志；`_heal_test.sh` 会直接
杀掉 shim，报告它多久回来。

## 端点

| 路由 | 用途 |
| --- | --- |
| `GET /health` | shim 存活、上游、订阅模型数量、支持的 wire |
| `GET /v1/models` | 16 个 `cline-pass/*` 订阅模型 |
| `POST /chat/completions` | 代理补全（OpenAI wire） |
| `POST /v1/messages` | 代理补全（Anthropic wire，带翻译） |
| `POST /v1/messages/count_tokens` | 本地 token 估算 |

## 空补全由这一层重试，不交给调用方

网关会间歇性地回一个格式完好的 200，但补全是空的：`finish_reason=stop`、无内容、
无错误。这和工具数量无关 —— 三个工具和二十四个一样容易触发：

```text
POST /v1/messages?beta=true model='cline_dsflash' cv=6 msgs in=4.8k tools=24
POST [auto] empty response content (finish_reason=stop)
POST /v1/messages?beta=true -> HTTP 500 (empty) after 1 channel(s)
```

客户端会把这个 500 当成可重试的 API 错误，自己开始退避 —— 屏幕上那句
`API error . Retrying in 1s . attempt 2/10` 就是这个意思。shim 改成自己重发：
那一刻什么都还没提交，调用方一个字节都没看到，而重发同一个 body 会成功，因为
上游是按请求重新掷骰子的。十个带工具的轮次实测，客户端可见的失败从大约一半降到
**0/10**。

两个细节让这件事成立。`RETRYABLE_EMPTY` 是一个内部状态，意思是"空了、值得重发"，
和路由未命中（带 200、必须换下一个 channel）区分开；`final_status()` 在它到达
调用方之前映射成 500。单独一次尝试也会拿到比钉选更宽的重试预算，因为它没有下
一个 channel 可以 failover。

卡顿是另一个问题，这个修不了：那十轮里有三轮花了 77s、98s、130s，而中位数是
24.8s。那是上游排队时间，实测唯一能撬动它的杠杆是输入大小 —— 见下。

## 上下文大小才是主导变量

把一个别名沿着会话真正会到达的尺寸往上走，`max_tokens` 全程 400：

| 输入 | 缓存命中 | 首 token | tps |
| --- | --- | --- | --- |
| 3k | 0% | 2.27s | 79.9 |
| 17k | 19% | 3.72s | 85.0 |
| 34k | 49% | 5.25s | 68.2 |
| 68k | 79% | 7.93s | 28.7 |
| 102k | 53% | 11.59s | 19.8 |
| 170k | 59% | 18.80s | 13.9 |

悬崖在 34k 到 68k 之间：速率在那里腰斩并持续下滑，而首 token 时延大致线性增长。
会话日志显示主模型平均输入 **57.6k**、峰值 **98.3k**，所以一个真实工作会话大半
时间待在这条曲线的陡坡上 —— 这就是为什么刚开新会话时吞吐很高、一小时后很低。
缓存命中率爬到 79% 也救不了，因为真正付的是网关在 prefix 之外那份按请求的开销。

压缩是能撬动它的杠杆，在 67k 上下文上背靠背实测：

```text
before /compact   in 67601  cached 67584  ttfb 5.77s  tps 67.0
after  /compact   in   130  cached     0  ttfb 1.83s  tps 53.8
before /compact   in 67601  cached 67584  ttfb 6.74s  tps 17.8
after  /compact   in   130  cached     0  ttfb 2.61s  tps 31.2
before /compact   in 67601  cached 66304  ttfb 6.91s  tps 20.4
after  /compact   in   130  cached     0  ttfb 2.14s  tps 37.0
```

中位数 20.4 -> 37.0 tps，首 token 6.5s -> 2.2s。把一个会话用一整天，才是让模型
看起来"退化了"的原因；别名从来没变过。

## 目录结构

shim 住在 WSL 发行版里，不在 Windows 盘上：

| 路径（WSL） | 内容 |
| --- | --- |
| `~/openai4s-shim` | `shim.py`、`ctl.sh`、`autostart.sh`、日志，以及 `_verify.sh` / `_diag.sh` / `_heal_test.sh` 检查脚本 |
| `/etc/systemd/system/cline-shim.service` | 监督 shim（`Restart=always`）并在发行版启动时拉起它的 unit |

从 Windows 侧可达路径是 `\\wsl.localhost\Ubuntu\home\<user>\...`。

## 测试

本仓库没有单元测试套件 —— 没有 `pytest.ini`、没有 `conftest.py`、没有
`test_*.py`。有的是几个运维检查脚本，而这里的失效模式确实只需要这些：

| 脚本 | 运行位置 | 用途 |
| --- | --- | --- |
| `_verify.sh` | WSL | 端到端状态：`boot_id`、`uptime`、unit 状态、端口监听、`/health` |
| `_diag.sh` | WSL | unit 状态、阻塞依赖、两份日志 |
| `_heal_test.sh` | WSL | 杀掉 shim，报告 systemd 多久把它拉回来 |
| `_gwctl.sh` | WSL | 在 8789 上以 gateway 模式跑第二个 shim 实例 |
| `_deploy.sh` | WSL | 推送改过的 `shim.py` 并重启 |

`tests/_e2e.py` **有意不**随仓库分发。它是活协议探针，不是单元测试：它驱动八组
`CLINE_SHIM_PIN` 组合（`CLINE_SHIM_PIN_MODE`、`CLINE_SHIM_EXCLUDE`），对真实网关
调 `/channels?model=...&discover=1`，并比对 `/health`。这些路径每一条都需要活的
上游和可用的订阅 key，所以在没有凭证的机器上它根本跑不起来 —— 第一个请求就失败。
把它公开等于描述一个没人能执行的测试，而且它的结果是"当天上游哪些 channel 恰好
健康"的快照，不是这段代码的性质。它不随仓库分发的原因和其它探针一样：见
`.gitignore` 里的 `tests/_probe*`。`.gitignore` 里那一行就是这个决定的记录。

想在本地重跑，把它放在 shim 旁边并给它需要的环境：

```bash
cd ~/openai4s-shim
CLINE_SHIM_PIN_MODE=strict python3 tests/_e2e.py   # 需要真实网关 + key
```

## 安全说明

- **不要把 8788 改绑到 `0.0.0.0`。** shim 会原样转发调用方发来的
  `Authorization` 头。在回环上那是你自己的客户端；绑到局域网接口上，它就变成了
  一个开放中继 —— 任何能访问该端口、并且自带 key 的人都能用。仓库里没有任何东西
  是按这种用途设计的。
- **shim 不存凭证。** `shim.py` 只用标准库，磁盘上不留 key，日志里写的是请求
  元数据（模型、消息数、输入大小估算），不是请求体。
- **日志仍可能敏感。** 里面有模型 id、尺寸和耗时。介意的话，别把
  `~/openai4s-shim` 放在任何同步或共享路径上。
