# service.json 字段说明

> `example` 是模板服务（`hidden: true`），不出现在 WebUI 服务列表中。
> 新建服务时（WebUI 或 `POST /api/services`）自动克隆本目录；
> 也可手动复制本目录为 `services/<新名称>/` 后修改。脚本中的 TODO 替换为真实命令即可。

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `name` | string | 是 | 服务名，**必须与目录名一致**，仅允许字母数字 `._-` |
| `description` | string | 否 | 服务描述（WebUI 展示） |
| `hidden` | bool | 否 | `true` = 模板服务：不出现在列表、不可启动。仅 example 使用 |
| `nodes` | string[] | 否 | **目标节点白名单**：空/缺省 = 允许集群全部节点；非空时仅允许列出的节点（如 etcd 仅 `["node4"]`），接口层校验拒绝越界 |
| `allow_duplicate_start` | bool | 否 | **重复启动保护**（默认 `false` = 保护开启）：同节点已有运行中实例时拒绝启动，需先停止或使用重启；`true` 允许重复启动（旧实例记录将被覆盖，旧进程需自行管理） |
| `workspace` | string | 是 | 服务在各节点上的部署根目录（所有部署节点同一路径）。绝对路径或 `~/` 开头 |
| `start.script` | string | 否 | 启动脚本，服务目录内相对路径，默认 `start.sh` |
| `start.args` | string[] | 否 | 启动脚本的固定参数 |
| `start.log` | string | 否 | 日志文件名（如 `master.log`），实际写入 `<workspace>/logs/<run_id>/<该文件名>`，每次启动独立归档、永不覆盖 |
| `stop.script` | string | 否 | 自定义停止脚本；缺省时按 PID 文件 kill（`stop.timeout` 秒后强杀） |
| `stop.timeout` | number | 否 | 默认 kill 方式的等待秒数，默认 10 |
| `deploy.files` | string[] | 否 | 需下发到节点的文件（支持 glob）；缺省 = 全部文件（`service.json`、隐藏文件除外）。**注意 README.md 等说明文件不应列入** |
| `variables` | object | 否 | 默认环境变量（注入 start.sh），启动任务时可覆盖 |

## 节点上的目录布局

```
<workspace>/
├── start.sh / stop.sh ...     # deploy.files 下发的文件
├── logs/
│   ├── 20261025-153045/service.log   # 每次启动独立目录（run_id = 启动时间戳）
│   └── ...
└── run/
    └── <服务名>.pid            # 最近一次启动的 PID
```

## 服务与实例的关系

- **服务**是模板（配置 + 脚本），选择若干节点「启动」后，每个 (服务, 节点) 成为一个**实例**
- 实例是操作单位：重启 / 停止 / 查看日志均针对具体实例
- 适用于**运行至完成**的任务（如编译）：进程退出后实例显示「已退出」及**退出码**
  （写入 `logs/<run_id>/exit_code`，0 = 成功；无码 = 被停止/终止）；重跑请使用「重启」
