# Services-Deployment

集群服务部署管理工具：Windows/Linux 管理端 + openEuler aarch64 节点集群。

通过 WebUI 或 REST API（供 AI Agent 调用）在集群节点上远程**部署 / 启动 / 停止 / 重启**服务，
日志始终保存在节点侧并按启动时间归档，支持从管理端**实时查看**。

```
┌───────────────┐   HTTP/WS    ┌─────────────────────┐    SSH/SFTP    ┌──────────────────┐
│  管理端 PC     │ ───────────► │  Backend (本项目)    │ ─────────────► │  集群节点          │
│  • 浏览器WebUI │              │  FastAPI + asyncssh │                │  openEuler aarch64│
│  • Agent      │              │  REST API + WS      │                │  零依赖：仅 bash   │
└───────────────┘              └─────────────────────┘                └──────────────────┘
```

节点侧**无需安装任何 agent**，所有操作经 SSH 完成（要求已配置免密登录）。

## 快速开始

### 1. 安装依赖（管理端，Python ≥ 3.10）

```bash
pip install -r requirements.txt
```

### 2. 配置集群

复制样例并按实际环境修改：

```bash
cp cluster.example.json cluster.json   # Windows: copy cluster.example.json cluster.json
```

`cluster.json` 内容：

```json
{
  "defaults": {
    "username": "root",
    "port": 22,
    "private_key": "~/.ssh/id_rsa",
    "connect_timeout": 10
  },
  "nodes": [
    { "name": "node1", "ip": "192.168.1.11" },
    { "name": "node2", "ip": "192.168.1.12", "port": 2222, "username": "openeuler" }
  ]
}
```

- `defaults` 提供全局默认值，节点内同名字段可覆盖（`name` / `ip` 必填）
- `private_key` 指向管理端私钥文件；若不存在则回退到 ssh-agent / 默认密钥

### 3. 启动后端

```bash
# Linux / macOS
./scripts/start_backend.sh
# Windows
scripts\start_backend.bat
# 或手动
python -m uvicorn backend.main:app --host 0.0.0.0 --port 8310
```

打开 `http://<管理端IP>:8310`（WebUI）或 `http://<管理端IP>:8310/docs`（OpenAPI 文档）。
端口可用环境变量 `PORT` 修改。仓库已附带构建好的 WebUI（`backend/static/`），
如需修改前端：`cd web && npm install && npm run build`。

## 服务定义：`services/<服务名>/`

每个服务一个目录，包含 `service.json` + 启动脚本（+ 可选停止脚本/配置文件）：

```json
{
  "name": "etcd",                             // 必须与目录名一致
  "description": "etcd 集群",
  "nodes": ["node4"],                         // 目标节点白名单：空/缺省 = 全部节点；配置后仅允许列出的节点
  "workspace": "/data/services/etcd",         // 必填：该服务在各节点上的部署根目录（所有节点同一路径）
  "start": {
    "script": "start.sh",                     // 服务目录内相对路径
    "args": [],
    "log": "etcd.log"                         // 日志文件名（存入 logs/<run_id>/ 下）
  },
  "stop": { "script": "stop.sh", "timeout": 10 },  // script 可省略 → 默认按 PID kill
  "deploy": { "files": ["start.sh", "stop.sh"] },  // 可省略 → 下发全部文件（service.json 除外）
  "variables": { "ETCD_PORT": "2379" }        // 默认环境变量，启动任务时可覆盖
}
```

- 模板：`services/example/` 含全部字段示例与逐字段说明（README.md），不出现在服务列表、不可启动
- 新建服务：WebUI「服务管理 → 新建服务」输入名称即可（自动克隆 example 模板），或手动复制 example 目录
- 隐藏标记：`"hidden": true` 的服务仅作模板，列表不显示、接口拒绝启动

**服务与实例**：服务是模板（配置+脚本）；在若干节点上「启动」后，每个 (服务, 节点) 成为一个**实例**——重启、停止、查看日志均针对具体实例操作。

**节点目录布局**（`workspace` 即服务根目录）：

```
<data/services/etcd>/
├── start.sh ...            # 下发的服务文件
├── logs/
│   ├── 20261025-153045/master.log    # 每次启动独立归档，永不覆盖/续写
│   └── 20261025-161230/master.log
└── run/
    └── etcd.pid                           # 最近一次启动的 PID
```

启动机制：`cd <workspace> && nohup env K=V bash start.sh > logs/<run_id>/<log> 2>&1 &`。
不做成功性判定——只要 nohup 派发成功、拿到 PID 即任务成功；启动失败请直接查看该 run_id 的日志。

## WebUI 使用

| 页面 | 功能 |
|---|---|
| 集群节点 | 节点列表、SSH 连通性测试（结果保留）、每节点端口监控（抽屉：监听端口/占用进程/过滤）、端口查询（多节点占用对照）、配置热重载 |
| 服务管理 | 列表（新建=克隆 example 模板、全量刷新）→ 每个服务子页面：配置编辑（含目标节点白名单，保存写回 service.json，编辑中禁止操作）、启动实例（仅白名单节点可选）、运行实例表（探活/重启/停止/查看日志） |
| 日志查看 | 多标签实时日志：每个标签独立会话（服务+节点+批次），WebSocket `tail -F`、下载快照；标签内搜索（高亮/上下跳转/首尾/仅显示匹配行）、意外断开自动重连（3s 退避，可关）；从服务页/任务页跳转自动连接 |
| 任务历史 | 任务列表展开查看每个节点的结果（PID / run_id / 错误 / 耗时），展开时懒加载详情 |

页面切换保留状态（测试结果、日志流缓冲等）；编辑服务配置保存前禁止启动/停止/重启操作。

## Agent / REST API

WebUI 与 Agent 使用**同一套 REST API**，FastAPI 自动生成 OpenAPI 文档（`/docs`），
Agent 可据此自主发现接口。常用调用示例（`BASE=http://<管理端>:8310`）：

```bash
# 列出集群节点
curl -s $BASE/api/cluster/nodes
# 测试某节点连通性
curl -s -X POST $BASE/api/cluster/nodes/node1/test

# 列出服务定义（模板服务 example 不显示）
curl -s $BASE/api/services

# 新建服务（克隆 services/example 模板）
curl -s -X POST $BASE/api/services -H 'Content-Type: application/json' -d '{"name":"etcd"}'

# 全量重扫 services/ 目录（新增/删除/外部修改服务后调用）
curl -s -X POST $BASE/api/services/reload

# 修改服务配置（写回 service.json；此处未提供的字段保持原值）
curl -s -X PUT $BASE/api/services/etcd -H 'Content-Type: application/json' \
  -d '{"nodes":["node4"],"workspace":"/data/services/etcd"}'
# 重新从磁盘读取某服务的 service.json
curl -s -X POST $BASE/api/services/etcd/reload

# 查询某节点监听端口及占用进程（ss -tulnpH）
curl -s $BASE/api/cluster/nodes/node1/ports

# 在 node4 上启动 etcd（先自动下发文件），覆盖变量
curl -s -X POST $BASE/api/tasks -H 'Content-Type: application/json' \
  -d '{"service":"etcd","action":"start","nodes":["node4"],"variables":{"ETCD_PORT":"2379"}}'
# → {"id":"<task_id>","run_id":"20261025-153045",...}

# 查询任务结果（每个节点子任务的 PID / 日志路径 / 错误）
curl -s $BASE/api/tasks/<task_id>

# 停止 / 重启实例（针对具体节点）
curl -s -X POST $BASE/api/tasks -H 'Content-Type: application/json' \
  -d '{"service":"etcd","action":"stop","nodes":["node4"]}'

# 运行实例与探活状态
curl -s $BASE/api/instances

# 读取最新一批日志（尾部 200 行）；run_id 可指定历史批次
curl -s "$BASE/api/logs/services/etcd/nodes/node4/content?run_id=latest&tail=200"
# 列出节点上的全部日志归档批次
curl -s "$BASE/api/logs/services/etcd/nodes/node4/archives"

# 实时日志流（WebSocket，多节点逗号分隔合并视图）
websocat "$BASE/api/logs/ws/logs?service=etcd&nodes=node4&run_id=latest&tail=100"
```

任务动作：`deploy`（仅下发文件）、`start`（下发 + 启动，生成实例）、`stop`、`restart`（实例级操作）。
服务的 `nodes` 白名单会限制可用节点，越界请求返回 400。启动顺序由你手动控制
（例如先 Master 后 Store，依赖地址通过启动时的 variables 传入实际值）。

## 项目结构

```
├── cluster.json          # 集群配置（唯一真源）
├── services/             # 服务定义（service.json + 脚本）
├── backend/              # FastAPI 后端（api / ssh / deployer / executor / tasks / logs）
├── web/                  # Vue3 + Element Plus 前端源码
├── scripts/              # 双平台启动脚本
├── tests/                # 单元测试（pytest）
└── data/                 # 运行时状态（tasks.json / instances.json，自动生成）
```

## 注意事项

- 前提：管理端可 SSH 免密登录所有节点（密钥无口令，或使用 ssh-agent）
- `workspace` 支持绝对路径（推荐）或 `~/` 开头（会在节点上展开）
- WebUI/API 当前无鉴权，仅适用于可信局域网；请勿暴露到公网
- 服务以 nohup + `setsid` 独立进程组运行：停止时**整组终止**（脚本及其全部子进程），脚本内不 exec 真实服务也能可靠停止；节点重启后不会自动拉起
- 停止采用严格验证：pid 文件含进程启动指纹（防 PID 复用误杀），组杀后确认进程退出，未退出则任务如实报 `STOPFAIL` 失败；指纹不匹配报 `PIDREUSED`（拒绝误杀）、旧格式 pid 文件报 `LEGACY`（升级前启动的实例，需按提示在节点上手动清理）
- 探活基于同一指纹：`运行中 / 已退出 / 旧实例(需手动处理) / PID复用`，避免 PID 复用误判
- 日志流使用**独立 SSH 专用连接**（与连接池隔离，池连接重建/异常不会中断日志流），并启用 keepalive（15s）检测死链；WebUI 意外断开时自动重连
- 端口监控基于 `ss -tulnp`：SSH 用户为 root 时可见全部占用进程，非 root 仅能看到自己进程的 PID/名称
- 日志按启动时间归档永久保留在节点上，如需清理请自行删除 `logs/` 下的历史批次目录
- 开发调试前端：`cd web && npm run dev`（Vite 代理到 `localhost:8310`）

## 测试

```bash
python -m pytest tests/ -q
```
