# OpenAI4S 启动器（WSL 承载）

[English](README.md) | **简体中文**

Windows 侧的入口，用来驱动一套跑在 WSL 内、经由 Cline Pass 订阅网关供能的
OpenAI4S 安装。

## 使用方式

| 命令 | 作用 |
| --- | --- |
| `openai4s.cmd start` | 拉起 shim 与 daemon，保住虚拟机，打开 Web UI |
| `openai4s.cmd stop` | 停止 daemon 与 shim |
| `openai4s.cmd restart` | 先 stop 再 start |
| `openai4s.cmd status` | shim 健康状态 + daemon 状态 |
| `openai4s.cmd doctor` | OpenAI4S 环境自检 |
| `openai4s.cmd logs` | 跟踪 daemon 与 shim 日志 |
| `openai4s.cmd url` | 打印并打开 Web UI 地址 |
| `openai4s.cmd shell` | 在安装目录里开交互式 shell |

`start` 支持 `-NoBrowser` 跳过打开浏览器，例如 `openai4s.cmd start -NoBrowser`；
`logs` 支持 `-Tail N`。

## 为什么跑在 WSL 里

OpenAI4S 需要 Windows 不提供的 POSIX 进程原语：`start_new_session=True`、
每 cell 独立进程组并精确投递 `SIGINT`、以及 bubblewrap / Seatbelt 沙箱后端。
`openai4s/platform_support.py` 只接受 `darwin` 与 `linux` 前缀，在原生 Windows
上直接抛 `UnsupportedPlatform`，所以 daemon 跑在 Ubuntu WSL2 里。

## 为什么需要计划任务

WSL2 在最后一个 `wsl.exe` 客户端断开后就会拆掉虚拟机，拆机时里面所有进程一起
被杀，包括 `serve --detached` 的 daemon。默认 `vmIdleTimeout` 是 60 秒，所以一段
空闲会话在一分钟左右就会同时丢掉两个服务。

用 `Start-Process` 起的保活子进程活不下来：它会随着启动它的 PowerShell 一起被拆
掉，而那一拆恰好移除了最后一个挂载的客户端。交给任务计划程序托管后，`wsl.exe`
客户端就能活过启动器开的每一个 shell。

`start` 会注册 `OpenAI4S keepalive` 任务并 touch `~/.openai4s/.keepalive`；`stop`
删除该锁、停止任务并注销它。实测：完全静默 150 秒后，虚拟机启动时间未变，两个
端口都还在监听。

## 为什么要这个 shim

`https://api.cline.bot/api/v1` 说的是 OpenAI 协议，但有五个细节会让普通客户端崩掉：

1. 非流式回复被包在 `{"data": {...}, "success": true}` 里，OpenAI4S 的阻塞路径读
   `body["choices"]` 会抛 `KeyError`。
2. 推理内容以 `reasoning` / `reasoning_details` 到达，而 OpenAI4S 读的是
   `reasoning_content`。
3. 模型 id 必须是 `cline-pass/<name>`。裸 id（如 `z-ai/<name>`）会走 Cline
   Credits 而非订阅，返回 HTTP 402。
4. 路由未命中表现为 HTTP 500 `empty response content`，值得透明重试。
5. 网关自动选渠既不最稳也不最快，一次未命中就要赔上整个回合。

`shim.py` 在 `127.0.0.1:8788` 上把五个问题一次修掉，且不需要改动 OpenAI4S。
它只用标准库，原样转发调用方的 `Authorization` 头，不保存任何凭据。

在 `.env` 里把 OpenAI4S 指过来：

```dotenv
OPENAI4S_LLM_PROVIDER=ark
OPENAI4S_LLM_BASE_URL=http://127.0.0.1:8788
OPENAI4S_LLM_API_KEY=sk_...
OPENAI4S_LLM_MODEL=cline-pass/glm-5.3
```

裸模型名（`glm-5.3`）和上游目录 id（`z-ai/glm-5.3`）都会被归一成
`cline-pass/glm-5.3`。

## 上游固定

一个 Cline Pass 模型不是由一台机器提供的。网关把它路由到大约十五个推理渠道，
每次请求用哪一个由它自己决定。2026-09-17 在 `cline-pass/deepseek-v4.1-flash` 上
实测：路由器自己的选择每次都答对了，但落点散乱（8 轮里
`fireworks:4 alibaba:3 novita:1`），而这个池子里有些渠道要一分钟才吐出第一个字。
shim 用「自己点名渠道」消掉这场抽奖：同样的测量下，平均 1.4 秒而不是 2.5 秒，
而且每次都是同一台服务器。

### 协议格式

网关从 `providerOptions.gateway` 读取固定信息：

| 字段 | 含义 |
| --- | --- |
| `only` | 白名单，路由器必须用其中之一，否则失败 |
| `order` | 偏好列表，先试这些，再试其余 |
| `sort` | `cost` \| `ttft` \| `tps`，按指标选胜者 |

OpenRouter 的写法（`provider.only` / `provider.order`）会被接受但静默忽略：拿一个
不可能存在的渠道名分别按两种写法固定，只有 `providerOptions.gateway` 那种让路由器
发出了抱怨。`sort` 也没法折进 `order` 的列表里——这个网关对 `order` 里的未知渠道名
是**直接拒绝**而不是降级，所以一个没验证过的名字是硬失败，不是回退。

### 两条规则

* **只有在首字之前才允许容错。** 一旦内容送达调用方，回复就归调用方所有，重发
  等于重复输出。流式线上的一次路由未命中**不是** HTTP 错误——网关会返回
  `200 text/event-stream`，而它的第一帧就是
  `{"error":{"code":"stream_initialization_failed",...}}`。因此 shim 会先扣住帧，
  直到某一帧真的带了内容，才提交这个 200。一条结束却没有内容的流会变成
  `EMPTY_RESPONSE`，与参考实现 `dsh-cline-pass` 适配器得出同样的结论。
* **坏 key 和额度墙永不重试。** 每个渠道都在同一个账号后面，轮换它们只是把失败
  重演一遍。其余情况——路由未命中、渠道排满、流被掐断——都是渠道级问题，正是
  下一次尝试存在的意义。

### 默认顺序

`cline-pass/deepseek-v4.1-flash` 的内置顺序是 `togetherai, novita, deepinfra,
parasail, alibaba, runware, boundless, gmicloud`：这是实测时干净应答的子集，按观察
到的首字延迟排序。其余渠道并非因为坏掉被排除——容量一天之内就会变（`fireworks`
早上满负荷，晚上在 8 轮未固定的轮次里服务了 4 轮）——但固定只有在稳定时才划算，
所以顺序里只放了既快又持续在线的服务器。

### 配置

| 变量 | 默认值 | 含义 |
| --- | --- | --- |
| `CLINE_SHIM_PIN_MODE` | `strict`（经 `ctl.sh`） | `strict` \| `preferred` \| `off` |
| `CLINE_SHIM_PIN` | *（内置）* | 逗号分隔的渠道顺序 |
| `CLINE_SHIM_EXCLUDE` | *（无）* | 要绕开的渠道 |
| `CLINE_SHIM_BUDGET` | `120` | 用于容错的秒数，不含生成本身 |

`preferred` 用 `order` 走这个列表，路由器仍可能落到未验证的渠道。`strict` 依次用
`only` 逐个固定渠道——这是强行使用冷门渠道的唯一办法，代价是某个死渠道会在一次
尝试内变成硬失败，然后 shim 才移到下一条。`off` 恢复纯透传。

各跑 8 轮流式实测：`off` 8/8，平均 2.5 秒；`strict` 8/8，固定单渠道平均 1.4 秒；
`preferred` 7/8（一次空回复，来自路由器落到的那个渠道）。`off` 并非坏掉，固定它
的理由是 dsh 的一轮很长，首字才是昂贵的那部分，稳定的 1.4 秒胜过浮动的 1.5 至 4 秒。

### 查看方式

| 路由 | 用途 |
| --- | --- |
| `GET /health` | 存活、固定模式、排除项 |
| `GET /models` | 订阅内模型 id |
| `GET /channels?model=<id>` | 某个模型解析出的尝试顺序 |

`/channels` 默认报告内置顺序。加 `&discover=1` 会花掉一次请求（不耗 token，路由器
在生成前就失败了），让网关自己报出渠道名，并缓存一小时。

## 保活机制

有两件事让「启动一下就行」不成立：

1. `settings.yaml` 里 dsh 的 `cline` provider 指向 `http://127.0.0.1:8788` 且没有
   回退，所以 shim 停了就等于 dsh 完全答不了话。
2. shim 跑在 WSL2 虚拟机里，而最后一个 `wsl.exe` 客户端脱开约 60 秒后，WSL2 就会
   拆掉虚拟机，把 shim 一起带走。

三层各管一个失效点：

| 层 | 管什么 | 手段 |
| --- | --- | --- |
| `Cline shim` 计划任务 | 虚拟机 | 常驻的 `wsl.exe -d Ubuntu -- sleep infinity`，始终有客户端挂着，虚拟机不会空闲退出 |
| `cline-shim.service`（systemd） | shim 进程 | `Restart=always`，5 秒——实测被杀后 3 秒回来 |
| `autostart.sh` | 端口 | 调 `ctl.sh start`，之后每 30 秒复查一次（幂等——`ctl.sh` 在端口被占用时立即返回） |

这层拆分是有意的。`autostart.sh` 是个循环，正因为如此它也顺带顶住了虚拟机——那
是最初的设计，计划任务直接跑它。但那让计划任务成了 shim 的第二个管理者，每次任务
启动都会在 systemd 旁边多留一个 supervisor。现在计划任务只管虚拟机，systemd 管
shim，supervisor 只有一个。

一并注册两层：

```powershell
powershell -ExecutionPolicy Bypass -File install-autostart.ps1
powershell -ExecutionPolicy Bypass -File install-autostart.ps1 -Remove
```

它通过 `wsl -u root` 装上 systemd unit，并注册一个登录触发的任务 `Cline shim`，
以当前用户身份运行。不设在开机时：WSL 发行版是按用户隔离的，SYSTEM 任务看不到
发行版。也不放在启动文件夹——`Start-Process` 的子进程会随启动它的 shell 一起拆掉，
那会移除最后一个挂载的客户端，让虚拟机空闲退出。交给任务计划程序托管 `wsl.exe`
客户端，它才能活过启动器开的每一个 shell。

这个任务刻意独立于 `OpenAI4S keepalive`（那个会被 `openai4s.cmd stop` 注销）。
它是给 dsh 用的机器级设置，能活过上述操作。删除该任务不会停掉 shim——那要用
`~/openai4s-shim/ctl.sh stop`。

### 两个坑

两个都踩过，而且都表现为「shim 没起来」。

**别让 unit 依赖网络。** 一行 `After=network-online.target` 看着无害，其实不是：
网络断开时该 target 永远不会变 active，unit 就在那等，shim 永远不启动——尽管它只
监听回环、绑端口根本不需要网络。断网实测：`network-online.target` inactive，
服务 active，`/health` 正常。

**别给计划任务一条一次性命令。** 改成 `wsl.exe -d Ubuntu -- true` 会移除常驻客户
端，虚拟机一分钟后空闲退出，把 shim 带走。任务必须留一个活着的进程，`sleep
infinity` 是最小形态。

### 验证

```powershell
wsl -d Ubuntu -- bash -lc 'bash ~/openai4s-shim/_verify.sh'
```

关键是 `boot_id`：`boot_id` 不变而 `uptime` 增长，说明虚拟机一直活着；`boot_id` 变
了说明它重启过，而任务的常驻客户端没起作用。用 `wsl --shutdown` 加任务自身那条命
令端到端实测：全新 `boot_id`，服务 `active`，shim 在监听，`/health` 正常，只有一个
supervisor。

`_diag.sh` 在出问题时倾倒 unit 状态、阻塞依赖和两份日志；`_heal_test.sh` 直接杀掉
shim 并报告它花了多久回来。

## 没有 shim 会坏什么

| 消费方 | 配置位置 | 没有 shim 时 |
| --- | --- | --- |
| dsh（`settings.yaml`） | `baseURL: http://127.0.0.1:8788` | 没有回退。每个回合都以 `fetch failed` / `ECONNREFUSED` 失败，dsh 的分类器把它判为 `TRANSPORT`，于是退避重试 5 次后报传输错误。 |
| OpenAI4S（`.env`） | `OPENAI4S_LLM_BASE_URL=http://127.0.0.1:8788` | 同样的失败；它的 cell 跑不起来。 |
| Claude Code CLI | `~/.claude/settings.json` | 不受影响——它的 `ANTHROPIC_BASE_URL` 指向远程网关。把它指到 shim 上，就会继承被固定的渠道（见上面的 Claude Code 一节）。 |

## 环境选择

这里有两条解释器路径，而且它们不是同一条：

- **Web UI** 走 `openai4s/server/gateway.py`，它调用
  `environments.default_env_name()`，选中 `python` 这个 conda 环境；
- **CLI**（`openai4s run`）从不调用 `default_env_name()`——所有调用方都活在 server
  层——所以它用控制面解释器 `.venv/bin/python`（合成的 `base` 环境）启动 cell。

因此 `base` 必须带上与 conda `python` 环境相同的 24 个 `CORE_PACKAGES`。否则一个
CLI 任务无法 import seaborn/sympy/lxml，然后就会耗掉好几个回合去尝试在沙箱里
`pip install`（没有网络），或者去够一个根本没接上的审批通道。

用官方入口修，而不是手动 pip：

```bash
cd ~/openai4s
.venv/bin/python -c "from openai4s.kernel.preinstall import ensure_core; ensure_core(background=False)"
```

同一个 sympy 任务上实测：修之前 16 个 action group、约 89k 输入 token；修之后 4 个
action group、约 7.5k。

## 网关渠道固定

Cline Pass 把一个模型路由到约 15 个推理渠道，未固定时路由器按自己的启发式选择。
2026-09-17 在这里用 `cline-pass/deepseek-v4.1-flash` 实测：

| `CLINE_SHIM_PIN_MODE` | 结果 |
| --- | --- |
| `off` | 0/8——每个请求都 HTTP 500 `upstream_routing` |
| `preferred` | 10/10 |
| `strict` | 10/10 |

`ctl.sh` 默认 `strict`，因为 `off` 说明未固定的池子就是会失败的那个：`preferred`
的回落只能落到已知死掉的渠道上。`shim.py` 携带按首字延迟对活网关实测得到的渠道
顺序。`ctl.sh status` 报告的是运行进程实际持有的模式。

## 对 checkout 的本地补丁

有两个上游行为对这套安装来说是错的，且都在「一解压就被整体覆盖」的文件里。
`patch-openai4s.sh` 每次启动都会重新打上它们，所以升级会自我修复，而不是悄悄把它
们回退掉。

| 补丁 | 文件 | 修的是什么 |
| --- | --- | --- |
| gzip | `openai4s/webtools.py` | `_http_get` 在 `stream=True` 下产出 `response.raw`，而 requests 只通过 `.content` / `.iter_content` 解压，从不经过 `.raw`。于是 gzip 的 `Content-Encoding` 以原始字节送到调用方，被 `decode("utf-8", errors="replace")` 变成 U+FFFD。加一个标志 `response.raw.decode_content = True` 就让这条流转为透明。 |
| Cell 提示 | `openai4s/server/completions.py` | 每个成功的中间 Cell 之后都重复一句「recorded in the Notebook」，而动作前的叙述在一个回合前已经承诺过同样的事。指针去掉，计数保留。这是 Web UI 的叙述，不是模型上下文。 |

脚本是幂等的，无事可做时打印 `already applied`，遇到锚点已在上游移动的文件则原样
退出（退出码 3），不碰文件。

## 假 IP DNS

`web_fetch` 会拒绝解析到私有/回环网段的 URL，这是对的——但 Clash 风格的 Fake-IP
DNS 会把普通公网域名映射进 RFC 2544 的 `198.18.0.0/15`。`webtools` 只对出口目录
里的主机名接受该网段，由 `OPENAI4S_ALLOW_FAKE_IP_DNS` 开关控制。

上游的 `configure_fake_ip_dns` 要求 resolv.conf 的 nameserver **和**一次探测都落在
该网段里。这只在 Clash 把 DNS 监听器跑在 WSL 内部时成立。若用 Windows 侧的 Clash
TUN，`resolv.conf` 指向 WSL2 NAT 网关（`10.255.255.254`），而 `api.openalex.org`
仍解析到 `198.18.0.x`——于是上游的闸门保持关闭，每一次 `web_fetch` 都被拒绝，理由
是一个纯公网域名碰上了私有地址。

`detect-fake-ip.sh` 把探测结果当作决定性的，resolver 检查只保留为跳过查找的快路径。
它把结论写进两处：给启动器开的 shell 用的 `$ShimDir/.fake_ip.env`，以及 checkout 的
`.env`，因为 `openai4s run` 是与 daemon 分开的进程，普通终端否则会漏掉这座桥。

无论如何，这座桥都很窄：只对目录内主机名生效，永远不涉及 IP 字面量、回环、链路
本地或元数据地址。

## Claude Code

### 注册自定义模型 id

Claude Code 2.1.276 遇到自己目录里没有的模型 id 会拒绝启动：

```text
"cline_dsflash" isn't described by this version's model catalog; update Claude
Code, or map it with behavesAs on a modelPicker row ...
```

目录决定客户端该假设多大的上下文窗口、用哪套提示词配置、能力与 effort 默认值，
所以一个它从未听说的网关别名对这些统统没有答案。两条设置能修好，都是报错自己
给出的建议。

`modelPicker` 用来加行——不加 `replaceBuiltInOptions`，这些行会追加到内置阵容之后，
而不是替换它：

```json
"modelPicker": {
  "options": [
    { "model": "cline_dsflash", "label": "DS Flash (cline)",
      "behavesAs": "claude-haiku-4-5" }
  ]
}
```

`behavesAs` 指定一个**本构建认识**的模型，借用的只是客户端侧处理方式：提示词配置、
能力与 effort 默认值。**发往上游的 id 不会改变**，这正是关键——网关收到的仍然是
`cline_dsflash`，shim 日志可以证实。在本构建上用 `claude -p` 验证：退出码 0，没有
`[claude-code:unrecognized_model]` 行，没有目录阻塞，请求以 `cline_dsflash` 抵达网关。

本构建认识的 id（从 `~/.clawgod/bunfs` 读出）有 `claude-haiku-4-5`、
`claude-sonnet-4-5`、`claude-sonnet-5`、`claude-opus-4-8`、`claude-opus-5` 等。这里
映射到 haiku，因为那正是 `cline_dsflash` 在 `ANTHROPIC_DEFAULT_HAIKU_MODEL` 里占的
槽位；想换成 sonnet 或 opus 的处理方式，就把它指到对应 id。

下面这个逃生口也有效，值得为「出现在选择器之外的模型」留着做双保险：

```json
"CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT": "1",
"CLAUDE_CODE_MAX_CONTEXT_TOKENS": "200000"
```

### 网关模式

有两个不同的上游都值得让 Claude Code 连，所以 shim 有两种模式。
`CLINE_MODEL_MODE=gateway` 原样透传调用方的模型 id、不写固定信息，用于那套自己给
模型命名的远程 New API 网关；默认的 `prefix` 模式就是下面讲的 Cline Pass 行为。

```bash
# tests/_gwctl.sh start  ->  http://127.0.0.1:8789
CLINE_UPSTREAM=https://GATEWAY_HOST/v1
CLINE_MODEL_MODE=gateway
CLINE_SHIM_PIN_MODE=off
```

它跑在自己的端口上，所以永远不会打扰 8788 上的 Cline Pass 实例。把 Claude Code 指
过去只需要改 `ANTHROPIC_BASE_URL`，而 shim 原样转发调用方的 key——这里指的是
`https://GATEWAY_HOST` 本来就接受的网关 key，不是 Cline key。

它换来的是可观测性，不是速度：shim 多了一跳，所以不会比直连网关更快。它真正带来
的是每个请求一行日志，带着决定这条路由速率的那些数字。

```text
[cline-shim] POST /v1/messages model='cline_dsflash' stream cv=3 msgs in=2.0k tok (est) max=1.4k tools=0
```

`cv` 是消息条数，`in` 是输入估算（字符数 / 4，与本地 `count_tokens` 路由同一比例）。
盯住一段会话里的 `in`：过了大约 34k，速率就腰斩，这就是「长会话感觉比新会话慢」的
全部答案。

顺带说明这里为什么没有自动的上下文折叠。静默地总结历史会重写对话——模型会丢掉它
参与过的决定，由此产生的错误答案看起来像模型故障。它还会击穿前缀缓存，因为每个
请求都会携带不同的历史。`/compact` 用的是模型自己的理解来做总结，那是比按字节数
规则更好的摘要。

### 空回复在这里重试，而不是由调用方重试

网关会间歇性地回一个格式良好的 200，但补全是空的：`finish_reason=stop`、无内容、
无错误。日志里是这样，而且和工具数量无关——三个工具和二十四个一样容易复现：

```text
POST /v1/messages?beta=true model='cline_dsflash' cv=6 msgs in=4.8k tools=24
POST [auto] empty response content (finish_reason=stop)
POST /v1/messages?beta=true -> HTTP 500 (empty) after 1 channel(s)
```

Claude Code 把这个 500 当作可重试的 API 错误并启动自己的退避，屏幕上就是那句
`API error . Retrying in 1s . attempt 2/10`。现在 shim 自己重发请求：那个时刻什么都
还没提交、调用方一个字节都没看到，而重发同样的 body 会成功，因为上游每个请求都
重新掷一次。十个带工具的回合实测，客户端可见的失败从大约一半降到 **0/10**。

两个细节让它成立。`RETRYABLE_EMPTY` 是个内部状态，意思是「空的，值得重试」，与路由
未命中（带 200，必须换下一个渠道）区分开；`final_status()` 在触及调用方之前把它映射
成 500。单次尝试也会得到比固定尝试更宽的重试预算，因为它没有下一个渠道可以容错。

卡顿是另一个问题，这个改动不解决它：那十个回合里有三次分别耗时 77 秒、98 秒和
130 秒，而中位数是 24.8 秒。那是上游排队时间，实测能推动它的唯一杠杆是输入大小——
见上面的曲线。

### 对比 Cline Pass 池

Claude Code 在 `/v1/messages` 上说 Anthropic 协议，而它当时连的是一个**远程**网关，
不是这个 shim：

```json
"ANTHROPIC_BASE_URL": "https://GATEWAY_HOST",
"ANTHROPIC_MODEL": "cline_dsflash"
```

那个网关是挡在 OpenRouter 前面的一个 New API 实例。它的 `cline_dsflash` 别名解析到
`deepseek/deepseek-v4-flash-0731`，这几跳同时花掉延迟和吞吐，同一提示词上实测：

| 路由 | 首字 | 输出速率 | 最差中途卡顿 |
| --- | --- | --- | --- |
| 网关别名（它当时的行为） | 3.1–5.9s | 中位 24.9 tps（1.6–54.2） | **24.6s** |
| shim -> 固定的 cline-pass 渠道 | 1.1–1.6s | 38–156 tps | 0.2–2.1s |

token 计数本身就足够说明问题：最近 46 次 Claude Code 请求里，客户端时间戳与上游
自己的请求 epoch 之间的差值中位数是 13.5 秒，90 分位是 32 秒。那是网关排队加
OpenRouter 路由，不是模型在思考。

所以 `shim.py` 现在也终结这条线。`POST /v1/messages` 被翻译成 OpenAI body（系统提示
词内联、工具块转换、加上 `stream_options`），OpenAI 的帧被重新组装成 Anthropic
SSE：先是 `message_start`，然后索引稳定的 `thinking` 与 `text` 块，最后
`message_delta` 和 `message_stop`。`POST /v1/messages/count_tokens` 在本地作答。阻塞
式 body 被转换成 Anthropic 消息对象，`reasoning_content` 变成 `thinking` 块而不是被
丢掉。

把 Claude Code 指过来：

```json
"ANTHROPIC_BASE_URL": "http://127.0.0.1:8788",
"ANTHROPIC_AUTH_TOKEN": "sk_<the Cline key>",
"ANTHROPIC_MODEL": "cline-pass/deepseek-v4.1-flash",
"ANTHROPIC_DEFAULT_FABLE_MODEL": "cline-pass/deepseek-v4.1-flash",
"ANTHROPIC_DEFAULT_HAIKU_MODEL": "cline-pass/deepseek-v4.1-flash",
"CLAUDE_CODE_SUBAGENT_MODEL": "cline-pass/deepseek-v4.1-flash"
```

模型 id 必须是 `cline-pass/<name>`（或能归一到它的裸名）：网关私有别名如
`cline_dsflash` 在上游毫无意义，会被 HTTP 404 拒绝。`ANTHROPIC_AUTH_TOKEN` 必须是
Cline key——shim 原样转发——而不是那个网关用的 New API key。

有一个限制值得知道：Cline Pass 的固定信息活在 OpenAI 形状的 `providerOptions` 字段
里，所以 Anthropic 请求永远不会携带它。翻译层之后把它注入进去，这正是让这条路由
不只是更短、而是更稳的原因：没有固定信息时，同样的测量散布在 69–92 tps，最差帧间
隔 2.96 秒，还有一次阻塞式回合在一个单词的回答上花了 64.6 秒。有了固定信息，六轮
下来：110–153 tps，首字 1.03–2.43 秒，最差帧间隔 0.36 秒。

用这个 shim 在同一批模型上实测，`deepseek-v4.1-flash` 是池子里最快的（155.9 tps，
首字 1.10 秒，最差帧间隔 0.21 秒）；`glm-5.2`、`deepseek-v4-flash`、`glm-5.3` 和
`deepseek-v4-pro` 在 52–57 tps 区间；`glm-5.3-flash` 是那个要避开的异类（8.8 tps，
2.66 秒间隔）。

## 端点

| 路由 | 用途 |
| --- | --- |
| `GET /health` | shim 存活、上游、订阅模型数、协议线 |
| `GET /v1/models` | 16 个 `cline-pass/*` 订阅模型 |
| `POST /chat/completions` | 代理补全（OpenAI 协议） |
| `POST /v1/messages` | 代理补全（Anthropic 协议，经翻译） |
| `POST /v1/messages/count_tokens` | 本地 token 估算 |

## 免费的 `cline_dsflash` 别名

保留这一节，因为它回答的是另一个问题：不是「哪条路由最快」，而是「这个特定的免费
别名为什么慢」，而这个答案与 shim 毫无关系。

`cline_dsflash` 经 OpenRouter 解析到 `deepseek/deepseek-v4-flash-0731`。在同一个
400 token 提示词上跑六轮，与其他能解析的别名对比：

| 别名 | 上游 | 中位 tps | 首字 | 最差卡顿 |
| --- | --- | --- | --- | --- |
| `cline-free/deepseek-v4.1-flash` | `deepseek/deepseek-v4.1-flash` | **68.6** | 2.34s | 0.64s |
| `sensenova_dsflash` | `deepseek-v4-flash` | 55.8 | 2.00s | 0.23s |
| `cline_dsflash` | `deepseek/deepseek-v4-flash-0731` | 22.7 | 3.15s | 1.28s |

在负载下和上下文增长时还暴露出两个行为：

* **并发不扩展。** 六条重叠流时 `cline_dsflash` 聚合 77.1 tps，而每条流掉到
  12–29 tps；`cline-free/deepseek-v4.1-flash` 聚合 320.9 tps，每流 48–120 tps。
  Claude Code 会为子代理、压缩和标题同时发好几个请求，所以每条流的数字才是「一个
  回合的手感」。
* **首字随提示词增长。** 从 1 轮到 30 轮（3.4k -> 101k 输入 token），
  `cline_dsflash` 从 2.32 秒涨到 11.47 秒，速率从 56.0 掉到 19.1 tps。网关**确实**
  在缓存——`cached_tokens` 报告 101120——所以这个增长是网关自己的每请求开销加
  OpenRouter 那一跳，不是缓存缺失。`/compact` 和保持会话短是唯一能推动它的杠杆。

`sensenova_dsflash` 在流重叠时会返回 429，所以尽管单请求数字更好，它不是可以随手
替换的。

**上下文大小才是主导变量，不是别名。** 把一个别名沿会话实际能达到的尺寸走一遍，
`max_tokens` 全程 400：

| 输入 | 缓存命中 | 首字 | tps |
| --- | --- | --- | --- |
| 3k | 0% | 2.27s | 79.9 |
| 17k | 19% | 3.72s | 85.0 |
| 34k | 49% | 5.25s | 68.2 |
| 68k | 79% | 7.93s | 28.7 |
| 102k | 53% | 11.59s | 19.8 |
| 170k | 59% | 18.80s | 13.9 |

悬崖在 34k 到 68k 之间：速率在那里腰斩并继续下滑，而首字延迟大致线性增长。会话日志
显示主模型平均输入 **57.6k**、峰值 **98.3k**，所以一段工作会话的一生都花在这条曲线
的陡峭段上——这就是为什么刚开新会话时吞吐很高，一小时后很低。缓存命中率爬到 79%
也救不了它，因为付出的是网关在前缀之上的每请求开销。

压缩是能推动它的杠杆，在 67k 上下文上背靠背实测：

```text
before /compact   in 67601  cached 67584  ttfb 5.77s  tps 67.0
after  /compact   in   130  cached     0  ttfb 1.83s  tps 53.8
before /compact   in 67601  cached 67584  ttfb 6.74s  tps 17.8
after  /compact   in   130  cached     0  ttfb 2.61s  tps 31.2
before /compact   in 67601  cached 66304  ttfb 6.91s  tps 20.4
after  /compact   in   130  cached     0  ttfb 2.14s  tps 37.0
```

中位 20.4 -> 37.0 tps，首字 6.5 秒 -> 2.2 秒。整天复用同一个会话，就是让模型看起来
退化的原因；别名从未改变。

## 关于能力检测

`openai4s/llm/capabilities.py` 把任何回环端点视为未证实，报告
`tool_calling=False`。这只改变一句催促文案的措辞：工具声明仍然会发出去
（`_model_tool_specs`），而 `agent/actions.py:route_action` 路由原生工具调用时并不
查询能力。原生的 `finalize_response` 路径与围栏式 cell 的 `host.submit_output` 路径
在这个 shim 上都能工作。

## 目录布局

应用活在 WSL 发行版里，不在 Windows 盘上：

| 路径（WSL） | 内容 |
| --- | --- |
| `~/openai4s` | OpenAI4S checkout + `.venv` 控制面 |
| `~/openai4s-shim` | `shim.py`、`ctl.sh`、`autostart.sh`、`keepalive.sh`、日志，以及 `_verify.sh` / `_diag.sh` / `_heal_test.sh` 三个检查脚本 |
| `/etc/systemd/system/cline-shim.service` | 监督 shim 的 unit（`Restart=always`），并在发行版启动时拉起它 |
| `~/.mamba` | Python 3.11 与 R 4.5.3 内核环境 |
| `~/.openai4s` | daemon 数据目录 |

从 Windows 侧可经 `\\wsl.localhost\Ubuntu\home\<user>\...` 访问。
