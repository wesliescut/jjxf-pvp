# 机甲旋风 · 跨网双人 PvP 联机层

把单机《机甲旋风》变成**跨互联网的 1v1 擂台**：一个独立启动器 + 一层擂台运行时脚本 + 一个可以自己部署的房间中继。

**不改动原版安装、不改动原版存档。** 所有运行产物都落在单独的隔离目录里。

---

## 一、这个仓库不包含什么

这一点请先看清，能省掉很多误会：

| 不包含 | 说明 |
|---|---|
| 游戏本体 | 需要自备「机甲旋风 兼容启动器 V1.45.2.1」及其游戏文件 |
| 两个扩展包 | 这两个我会提供 **jjxf.combat_core 1.1.27** 与 **jjxf.anim_guard 2.0.5** 两个 ZIP，版本固定，换版本会校验失败 |
| **任何可用的中继地址** | 本仓库**不内置**中继。`relay.json` 已被 `.gitignore` 忽略，程序默认不连任何服务器，必须自己部署（见第四节） |

也就是说：拿到这个仓库 ≠ 立刻能联机，你还需要**自己的 Cloudflare 中继**。

---

## 二、环境要求

- Windows 10 / 11 64 位
- 机甲旋风 兼容启动器 V1.45.2.1（本体）
- 两个扩展包 ZIP：`jjxf.combat_core-1.1.27.zip`、`jjxf.anim_guard-2.0.5.zip`
- **运行启动器**：直接用打包好的 exe 即可；从源码跑则需要 Python 3.11+
- **部署中继**：Node.js 18+（`npx wrangler`），一个 Cloudflare 账号（免费额度够用）

---

## 三、目录结构

```
outputs/
  dual_room_internet_gui.py   启动器主程序（Tkinter 界面）
  multiplayer_profile.py      隔离档案准备 / 游戏启动
  save_import.py              单机存档导入（只读副本，不改原档）
  dual_room.py                本体与扩展包校验、配置指纹
  relay_client.py             中继 HTTP 客户端
  runtime_multiplayer/        擂台运行时（Godot GDScript，会被拷进隔离档案）
    pvp_world.gd              擂台主逻辑（同步、命中判定、血条、聊天、限时）
    peer_sync.gd              传输层（WebSocket、状态广播）
    pvp_run.gd / pvp_target.gd 战斗控制器与对手代理
    pvp_hp_bar.gd             自绘血条控件
  assets/launcher/            启动器头像素材
  relay_worker/               中继：Cloudflare Worker + Durable Object
  relay_pages/                可选：workers.dev 被墙时的 Pages 转发入口
work/                         PyInstaller spec 与构建脚本
```

---

## 四、部署你自己的中继（必须做）

有两种方式，任选一种。**不需要装 Node、也不需要打开命令行**的方式是先看 4.1。

### 4.1 启动器一键部署（推荐给不熟悉命令行的玩家）

1. 打开启动器，在右侧「中继」卡片点 **部署**；
2. 弹窗里点 **打开 Token 页面**，进入 Cloudflare 的 API Tokens 页面；
3. 在模板列表里选 **Edit Cloudflare Workers**（列表里就有这一项），
   然后一路 **Continue to summary → Create token**；
   - 如果你用的模板列表里没有它，就选 **Start from scratch** 手动加两条权限：
     - `Account` → `Workers Scripts` → **Edit**
     - `Account` → `Account Settings` → **Read**
4. 复制生成的 Token（**只显示一次**），粘贴到弹窗第 1 栏；
5. 点 **开始部署**。

程序会自动完成：创建 Worker → 绑定房间对象（Durable Object）→ 开启 workers.dev 访问，
几十秒后日志里出现 `https://jjxf-two-player-lobby.xxx.workers.dev`，并**自动填进中继地址**、
写进 `relay.json`。

> 弹窗第 2 栏「账号 ID」**一般留空**。只有当程序提示“读不到账号列表”时，
> 才需要去 Cloudflare 首页右侧复制 32 位账号 ID 填进去
> （这种情况通常是 Token 没勾 `Account Settings: Read`）。

> 部署出来的 Worker 在**你自己的账号**下，与作者无关，额度也走你自己的免费额度。

**如果 workers.dev 在你那边连不上**（校园网常见），继续看 4.2 用 Pages 套一层，
或者在 Cloudflare 面板里给这个 Worker 绑一个自定义域名。

### 4.2 命令行部署（可选，与 4.1 等价）

需要 Node.js 18+；`npx` 会临时拉取 wrangler，不用单独安装。

#### 第一步：部署 Worker

```powershell
cd outputs\relay_worker
npx wrangler login          # 浏览器里点授权，登录自己的 Cloudflare 账号
npx wrangler deploy
```

成功后终端会打印类似内容：

```
Uploaded jjxf-two-player-lobby (4.02 sec)
Deployed jjxf-two-player-lobby triggers (1.89 sec)
  https://<你的 Worker 名>.<你的子域>.workers.dev
Current Version ID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

三个名字别搞混：

| 名字 | 出现在哪 | 含义 |
|---|---|---|
| `jjxf-two-player-lobby` | 命令行开头 | **Worker 名字**，来自 `outputs/relay_worker/wrangler.jsonc` 的 `"name"` |
| `<你的子域>` | 网址中间 | **你账号的 workers.dev 子域**，每个账号固定一个 |
| `https://....workers.dev` | 网址整条 | 可用的中继地址，可以直接填进启动器 |

> 只想用 workers.dev：到这一步就可以收工，把上面那条地址填进启动器即可。

#### 第二步（可选）：workers.dev 被墙时，用 Pages 转发

很多校园网会拦 `*.workers.dev`，但一般放行 `*.pages.dev`。
思路是建一个 Pages 项目，它只干一件事：把所有请求原样转给第一步那个 Worker。

**2.1 先确认两个名字对得上**

打开 `outputs\relay_pages\wrangler.jsonc`，里面只有两个字段需要你关心：

```jsonc
{
  "name": "<你的 Pages 项目名>",   // ← Pages 项目名，决定你最终拿到的网址
  "pages_build_output_dir": "./dist",
  "compatibility_date": "2026-11-09",
  "services": [
    { "binding": "LOBBY", "service": "jjxf-two-player-lobby" }
    //                            ↑ 必须和第一步的 Worker 名字完全一致
  ]
}
```

**① `"name"` —— Pages 项目名，也就是你最终的域名：`https://<这里填的名字>.pages.dev`**

- 必须**全 Cloudflare 唯一**（pages.dev 子域先到先得），**一定要改成你自己的名字**，例如：
  - `my-relay-project`
  - `another-relay-project`
- 命名规则：**只能用小写字母、数字和连字符 `-`**；不能出现大写、空格、下划线、中文；
- 名字一旦部署成功就会成为你的固定地址，别人再想用这个名字会失败。

**② `"services"[0].service` —— 必须等于第一步部署出来的 Worker 名字**

- 如果你没改过 `relay_worker/wrangler.jsonc`，保持 `jjxf-two-player-lobby` 即可；
- 如果你把它改成了 `my-relay`，那么这里也必须写 `my-relay`，两个文件要一起改。

**③ `"binding": "LOBBY"` —— 不要改**

`relay_pages/dist/_worker.js` 里写死了 `env.LOBBY.fetch(request)`。这个 `LOBBY` 就是绑定的名字，
改了 Pages 就找不到 Worker，会返回 404 / 1101。

**2.2 部署 Pages**

```powershell
cd outputs\relay_pages
npx wrangler pages deploy
```

不需要在命令里写项目名——`wrangler` 会直接读上面那个 `wrangler.jsonc`。
第一次部署如果提示 `Create a new project?`，回车确认即可。

> 如果你的 wrangler 版本较老、提示缺少 `--project-name`，就手动带上：
>
> ```powershell
> npx wrangler pages deploy dist --project-name 你刚才改的项目名
> ```

成功后终端会打印：

```
Success! Uploaded 2 files
✨ Deployment complete! Take a peek over at
https://my-relay-project.pages.dev
```

**这条 `https://xxx.pages.dev` 就是最终要填进启动器的中继地址。**

**2.3 验证通没通**

中继只接受 POST，所以用 GET 访问根路径，返回 **405** 就说明转发链路是通的：

```powershell
Invoke-WebRequest -Uri "https://你的项目名.pages.dev/" -Method GET
```

- `405 Method Not Allowed` → 正常；
- `404` → `_worker.js` 没带上，或者不是在 `outputs\relay_pages` 目录里执行的；
- `1101` / `522` → service binding 指向的 Worker 不存在或名字写错，回到 2.1 检查。

#### 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| Pages 报 project name already exists | 项目名被别人占了 | 换一个更独特的 `"name"` |
| pages.dev 访问返回 404 | 输出目录不对 / 缺 `_worker.js` | 确认在 `outputs\relay_pages` 下执行，且 `dist\_worker.js` 存在 |
| 返回 1101 或 522 | binding 指向的 Worker 不存在 | `"service"` 要和 Worker 名字一致，且 Worker 已部署成功 |
| 启动器连不上 | 填的是 workers.dev 但被网络拦 | 改用 pages.dev 地址，或给 Worker 绑自定义域名 |
| 部署报 `10079 Actor migration tag precondition failed` | 这个名字的 Worker 之前已经部署过（房间对象已存在） | 用 v44 及以后的启动器会自动跳过迁移只更新代码；旧版请换新版本或用 4.2 的 wrangler 方式 |

### 填进启动器

四种方式，优先级从高到低：

1. 命令行：`JJXF_PVP.exe --relay https://你的地址`
2. 环境变量：`JJXF_RELAY_URL=https://你的地址`
3. **exe 同目录的 `relay.json`**（推荐，填一次就行）：

```json
{ "relay_url": "https://你的地址" }
```

4. 界面里「中继」卡片的输入框，填完点「保存」（会写进上面的 `relay.json`）

> 地址必须以 `https://` 开头。
> **两个人必须填同一个地址**，否则各自在不同房间里。
> 中继只负责转发，不做战斗判定，所以换中继不影响战斗表现。

---

## 五、两个人怎么开一局

1. 双方都装好本体 + 两个固定扩展包，都填好同一个中继地址；
2. 房主点「创建房间」，把出现的**房间码**给对方；
3. 客人输入房间码，点「加入房间」；
4. 双方都点「导入单机存档」，选一个角色转换到**联机专用隔离档案**（单机原档不会被修改）；
5. 双方都点「进入双人 PvP」；
6. 游戏里走正常流程：**开始 → 选角色 → 自动进入擂台**。

### 对局规则

- **每局限时 5 分钟**，时间到按双方剩余血量比例判胜（相同则房主胜）；
- **每回合蓄力值从 0 开始**（不会一开局就有大招）；
- **起身保护**期间既打不掉血也抓不到人，保护结束恢复正常；
- 顶部左侧是自己、右侧是对手的长条血条（带掉血拖尾），中间是倒计时；
- 对局内 **回车** 打开聊天输入条，**回车** 发送，**Esc** 退出聊天（打字时角色不能动）。

---

## 六、隔离与安全

- 所有运行文件写入：`%LOCALAPPDATA%\JJXF_Internet_Room\isolated_game`
  勾选「本机双开（第二实例）」时用 `isolated_game_2`，两个窗口互不干扰；
- 单机存档只读取、不写入；导入时会先保存一份只读副本；
- 启动器只把运行时脚本和扩展包拷贝进隔离目录，不动游戏安装目录；
- 中继只转发消息，不保存战绩，不做任何判定。

---

## 七、中继协议（想自己写服务器的人看这里）

中继对外只有四个 HTTP 接口 + 一条 WebSocket：

| 接口 | 请求 | 返回 |
|---|---|---|
| `POST /create` | `{ "lock": {...} }` 配置指纹 | `{ "code", "host_token" }` |
| `POST /join` | `{ "code", "lock" }` | `{ "guest_token" }` |
| `POST /status` | `{ "code", "token" }` | `{ "connected": true/false }` |
| `POST /leave` | `{ "code", "token" }` | `{ "ok": true }` |
| `WS /game?code=..&token=..` | — | 房间消息 |

房间内消息类型（校验细节见 `relay_worker/src/index.js`）：

- `state`：双方各 20Hz 的位置/动作/血量快照（房主与客人互相发送）
- `hit_request`：**仅客人 → 房主**，客人的命中申请（含控制事件，id ≥ 1000000）
- `combat`：**仅房主 → 客人**，判定结果与打击反应
- `round`：**仅房主 → 客人**，回合开始/结束
- `chat`：双向，对局内聊天（≤120 字符）

设计要点：
- **判定权在房主**（host-authoritative），客人只上报"我打中了"，由房主结算；
- 房间级限流 45ms/连接（约 20 次/秒），单条消息上限 4096 字节；
- 中继不信任客户端：字段缺失或类型不对直接断开连接。

---

## 八、自己打包（生成 exe）

仓库根目录的 `JJXF_PVP_Original_Combat.spec` 是 **PyInstaller 的打包配置**，相当于一份“配方”：
入口程序、要塞进 exe 的素材、产物名字、要不要黑窗口，全都写在里面。
玩家下载的 exe 就是它产出的，**普通玩家不需要关心这一节**。

### 8.1 最简用法

```powershell
python -m PyInstaller --noconfirm JJXF_PVP_Original_Combat.spec
```

产物：`dist\JJXF_PVP_Original_Combat.exe`（单文件，双击即用，目标机器不需要装 Python）。

想指定输出位置：

```powershell
python -m PyInstaller --noconfirm --distpath outputs --workpath build JJXF_PVP_Original_Combat.spec
```

- `--noconfirm`：覆盖已有产物；不加会在覆盖前停下来问；
- 需要先装 PyInstaller：`pip install pyinstaller`（本项目用 6.12.0 验证通过）。

### 8.2 spec 里各段在干什么

```python
root = Path(SPECPATH)        # SPECPATH 由 PyInstaller 注入 = spec 所在目录（仓库根）

a = Analysis(
    [str(root / 'outputs' / 'dual_room_internet_gui.py')],  # 入口程序
    pathex=[str(root / 'outputs')],                         # import 搜索路径
    datas=[                                                 # 要打进去的非 Python 文件
        (… / 'runtime_multiplayer', 'runtime_multiplayer'), # 擂台 GDScript（启动器会拷进隔离档案）
        (… / 'assets' / 'launcher', 'assets/launcher'),     # 界面头像
    ],
)

exe = EXE(
    pyz, a.scripts, a.binaries, a.datas, [],
    name='JJXF_PVP_Original_Combat',   # 产物文件名
    console=False,                     # False = 不弹黑窗口（GUI 程序）
)
```

三个必须知道的点：

1. **`datas` 不能漏**：Python 代码会自动收集，但 `.gd` 脚本和 `.png` 头像不是 Python 模块，
   必须手动列进去，否则打出来的 exe 里没有擂台脚本，进游戏会失败；
2. **没有 `COLLECT` 段 = 单文件模式**：exe 启动时会把内容解压到 `%TEMP%\_MEIxxxx`，
   所以启动比普通程序慢一点点；也正因如此，`relay.json` 这种可写配置**要放在 exe 旁边**，
   不能打进包里（打进包会随 exe 每次解压重置）；
3. **`console=False`**：双击不弹黑框。代价是崩溃时看不到报错——
   排查启动问题时把它临时改成 `True` 重新打包，就能看到 traceback。

### 8.3 常见改动

| 想做什么 | 改哪里 |
|---|---|
| 换 exe 名字 | `EXE(...)` 里的 `name='...'` |
| 往包里加文件 | `datas` 加一行 `(源路径, '包内目录')` |
| 排查启动崩溃 | `console=False` → `True` |
| 加程序图标 | `EXE(...)` 加 `icon='app.ico'` |
| 加版本信息 | `EXE(...)` 加 `version='version.txt'` |
| 精简体积 | `Analysis(..., excludes=['numpy', 'PIL'])` |

### 8.4 注意

- **必须在仓库根目录执行**：`root = Path(SPECPATH)` 依赖 spec 的位置，换目录会找不到 `outputs\...`；
- 每次打包会生成 `build\`（中间产物，可删）和 `dist\`（产物），两者都已写进 `.gitignore`；
- 平时只改代码的话，**spec 不用动**，重新执行一次打包命令即可；
- `relay.json` 永远不进包、不进仓库。

## 九、已知限制

- 建议双方使用**同一版本**：跨版本可能因协议字段差异而失联；
- 房主有极轻微的先手优势（延迟插值导致），本地双开时更明显；
- 不支持观战、断线重连；对方掉线即结束本局；
- 中继依赖 Cloudflare；国内网络可能需要 Pages 转发或代理；
- 只支持 1v1，房间码一次只服务两个人。

---

## 十、许可与免责

**本项目不是开源软件**，采用「保留所有权利 / 仅限查看与使用」授权，完整条款见仓库根目录的 `LICENSE`。

- **允许**：下载、安装、在自己的电脑上运行（个人、非商业）；
  阅读源码用于学习交流；在**不修改**代码、注明出处的前提下转发本项目的原始发布包。
- **禁止**（未经作者书面许可）：修改、改写、二次开发后发布或分发（包括改名、换皮、拆分重组合）；
  商业使用（收费下载、收费联机服务、广告变现）；删除或隐藏作者署名与版本信息；
  把源码或二进制重新打包发布到其他平台。
- 如需二次开发或商业授权，请联系作者。

> 说明：GitHub 平台本身允许 fork，但 fork 不等于获得修改与分发授权；
> 未获许可的修改版发布属于侵权，作者可要求下架。

本项目不包含任何游戏本体资源。请自行准备游戏本体和单机版启动器，自行部署服务器；
使用产生的任何后果由使用者自行承担，与作者无关。
