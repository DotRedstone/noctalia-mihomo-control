# Noctalia Mihomo Control

独立的 Noctalia v5 插件。它只访问本机 `127.0.0.1` 的 Mihomo External Controller；面板初始关闭，点状态栏 widget 后打开。插件仓库不含订阅、节点、服务器地址、token、主机或用户配置。

## 功能与边界

| 功能 | 行为 |
| --- | --- |
| 五态状态栏 | 离线、启动中、运行中、停止中、异常；运行时显示模式、连接数、实时上下行 |
| 控制面板 | Rule/Global/Direct、分页代理组与节点选择、单组或全部组测速、前 40 条活动连接及逐条关闭、核心 API 重启 |
| 离线体验 | 完整的离线说明、刷新与设置入口；有 helper 时还可启动服务 |
| 可选生命周期 | 只执行宿主配置的绝对路径 helper，四个固定动词：`status/start/stop/restart`；不调用 sudo，也不假定 systemd |
| 外观与输入 | Noctalia MD3 语义色、简体中文与英文；面板原生控件支持 Tab、Shift+Tab、Enter/Space，Escape 关闭 |

控制器只从插件进程向 `http://127.0.0.1:<port>` 发请求；它不启动监听器，也不提供远程控制入口。插件不会修改 Mihomo 配置文件、订阅或系统服务。`POST /restart` 是 Mihomo **核心 API 重启**；helper 的 `restart` 是由宿主定义的**进程服务重启**，两者在 UI 中分开。

与社区 [`mdj2812/mihomo-control`](https://noctalia.dev/plugins/community/mihomo-control) 相比，本项目聚焦本机控制器、显式五态和可选的受限生命周期接口。社区实现支持远程 controller、保存多服务器配置和更多展示选项；本项目并不提供这些功能。实现参考的是 Noctalia 公共 API 和 Mihomo API 语义，没有复制社区插件代码。

## 要求与安装

- Noctalia v5，插件 API 至少 24；已在 Noctalia `v5.2.0` 的离线 lint 工具上验证。
- Mihomo External Controller 绑定 loopback，例如在**你自己的 Mihomo 配置**中设置 `external-controller: 127.0.0.1:9090`，并建议设置密钥。不要把密钥提交到此仓库。
- 不需要 `jq`、`curl`、`sudo` 或外部运行时依赖。

开发时从仓库根目录运行：

```sh
noctalia msg plugins source add nmc-dev path "$PWD"
noctalia msg plugins enable nmc/mihomo-control
```

也可以将 `mihomo-control/` 安装为 `$XDG_DATA_HOME/noctalia/plugins/mihomo-control/`，然后启用插件。用户可将发布仓库作为 `git` source 添加；仓库根目录的 `catalog.toml` 可供 Noctalia 索引。插件 ID `nmc/mihomo-control` 已在首个发布版本中固定。

在 Noctalia Settings → Plugins 中设置 `controller_port`（默认 `9090`）和可选的 `controller_secret`。密钥保存在用户自己的 Noctalia 设置中，作为 `Authorization: Bearer` 头发送给本机 API。设置 `helper_path` 前不会出现启动、停止、服务重启按钮。测速 URL 默认是一个通用的 204 探测地址，可按网络环境改成自己可信的 URL；该 URL 由 Mihomo 执行测速，插件只把它作为 URL 编码后的参数送到本机控制器。

在状态栏配置中添加：

```toml
[widget.mihomo]
type = "nmc/mihomo-control:widget"

[bar.default]
end = ["mihomo"] # 合并进现有 end 数组，不要覆盖其他 widget
```

也可手动打开面板：`noctalia msg panel-toggle nmc/mihomo-control:panel`。面板默认不会自动打开；点击 widget 才切换可见状态。

## 生命周期适配器协议

`helper_path` 必须是存在的绝对路径。插件用 Noctalia `runAsync` 的 argv 形式调用，不经过 shell，且只传一个固定动词：

```text
<helper> status
<helper> start
<helper> stop
<helper> restart
```

`status` 需在 stdout 第一行输出 `running` 或 `stopped` 并以 0 退出；其他输出或非零退出视为错误。`start/stop/restart` 成功时以 0 退出，失败时非零退出；插件不依赖 stderr 中的特定文本，避免泄露实现细节。helper 应自行限制可操作的目标和参数，并在 12 秒内退出。插件在约 18 秒仍未收到服务操作结果时报告超时，随后再次调用 `status` 确认服务状态。已停止的服务显示为正常离线；helper 失败，或报告 `running` 但 API 不可用，才显示异常。

启动与服务重启分两步显示：helper 返回成功且 `status` 为 `running` 后，面板进入“等待 API”状态；本机 `/version` 最长可等待约 180 秒，以容纳首次 Geo 数据初始化。面板显示剩余时间，可取消等待；取消不会停止服务，也不会接受迟到的 API 回调。健康检查超时会显示异常，点“刷新”可重新查询。核心 API 重启同样等待 `/version` 恢复。停止后再次调用 `status`，确认 `stopped` 才显示离线。

helper 是**宿主提供**的权限边界，不由插件生成、安装或提权。只配置可信、不可由低权限用户改写的 helper。插件的 Luau VM 是隔离执行环境，但 Noctalia 官方明确指出插件是可信代码，安装插件等同运行用户脚本。操作系统级授权必须由宿主单独约束，示例见 [NixOS dotfiles 接入](docs/dotfiles-integration.md)。

## 调试与测试

```sh
noctalia plugins lint mihomo-control
lua tests/service_test.lua
lua tests/ui_test.lua
noctalia msg plugin nmc/mihomo-control:service all refresh
noctalia msg panel-toggle nmc/mihomo-control:panel
```

测试使用 Lua 5.4 的 Noctalia API mock，不连接实际服务；真实会话中需分别验证 offline、API 在线、启停和错误路径。Luau 文件编辑会热重载，`plugin.toml` 修改需重新加载 Noctalia 配置。日志可从 Noctalia 用户服务查看。不要在日志、bug 报告或测试输出中贴 controller secret。

局限：Mihomo `/connections` 返回全量 JSON，插件仅向 panel 发布前 40 条；极大连接量时 JSON 解析仍可能成为瓶颈。全局测速最多同时测试 4 组，组数很多时可能持续较久；`/group/{name}/delay` 可能清除自动组的固定选择（Mihomo API 行为）。API 中断时转离线/异常态，流量归零；状态恢复后重新拉取。实机写操作与 helper 权限桥仍需在安装后验收，详见[验证记录](docs/verification.md)。

## 目录

```text
catalog.toml                 Noctalia 源索引
mihomo-control/plugin.toml   插件与设置声明
mihomo-control/service.luau  API、状态与 helper 生命周期
mihomo-control/widget.luau   状态栏显示
mihomo-control/panel.luau    控制面板
mihomo-control/translations/ 中英文翻译
tests/                       无网络 mock 测试
docs/                        接入与研究记录
```

## 来源与许可

- [Noctalia 插件开发](https://docs.noctalia.dev/noctalia/plugins/development/)、[运行时 API](https://docs.noctalia.dev/noctalia/plugins/development/runtime-api/)、[发布流程](https://docs.noctalia.dev/noctalia/plugins/development/workflow/)
- [Mihomo 官方 External Controller API](https://wiki.metacubex.one/en/api/)
- [社区插件公开功能页](https://noctalia.dev/plugins/community/mihomo-control) 与 [公开源码](https://github.com/noctalia-dev/community-plugins/tree/main/mihomo-control)

代码为 MIT License。`nmc` 是暂定插件 ID 前缀；首次公开发布前应确认无冲突并固定。
