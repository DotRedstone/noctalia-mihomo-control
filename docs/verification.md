# 验证记录（2026-10-11）

环境：Noctalia `v5.2.0 (08c3039)`，本机 loopback `127.0.0.1:9090` 存在监听，`GET /version` 返回 HTTP 200。未读取或记录用户密钥、订阅或节点地址。

| 检查 | 结果 | 边界 |
| --- | --- | --- |
| `noctalia plugins lint .` | 0 errors、0 warnings | manifest 与插件设置引用 |
| Lua 5.4 `service_test.lua`、`ui_test.lua` | 均通过；修正后重新运行 | mock 覆盖 helper 停止时离线、运行但 API 故障、125 秒后恢复、180 秒超时、取消后迟到回调、连接非空到 `null` 清零、等待 UI 与大列表结构 |
| `luac -p mihomo-control/*.luau` | 通过 | Lua 语法，不替代 Noctalia Luau 执行 |
| JSON 与 TOML 解析 | 通过 | 静态配置格式 |
| Noctalia path source 加载 | 修正后重新加载：`nmc/mihomo-control` 三个 entry 成功加载，service 启动；日志无该插件错误 | 当前桌面会话运行时，未配置 helper |
| 面板 IPC | `panel-open` 成功，`status` 显示 `activePanelId` | 没有自动把新 widget 放到用户的 bar |
| 大量代理组 | 首次发现 256 子项截断警告；改为分页/单组展开后重新打开，日志无该警告 | 实际当前本机 API 的只读数据 |
| 清理 | 修正后再次关闭面板、禁用临时插件、移除 `nmc-dev` source；原社区插件仍启用 | 未改用户 dotfiles |

没有对正在使用的 Mihomo 发出 mode、select、close、restart、delay 等写操作；也没有安装宿主 helper，因此这些行为目前由 mock 测试验证，尚不是实机端到端验收。宿主当前的 `mihomo.service` 仍由 `multi-user.target` 拉起；[接入文档](dotfiles-integration.md) 已要求宿主移除 `wantedBy`，但 NixOS dotfiles 尚未修改、部署或重启验证。Polkit 权限边界仍须在目标主机部署后测试。
