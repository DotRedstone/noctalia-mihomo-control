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

2026-10-11 的验证没有对正在使用的 Mihomo 发出 mode、select、close、restart、delay 等写操作，也没有安装宿主 helper；这些行为当时仅由 mock 测试覆盖。该日宿主仍有开机 `wantedBy`，[接入文档](dotfiles-integration.md)要求移除；后续宿主部署状态应以所属仓库和实机检查为准，不由这份历史记录推断。

## 配置管理扩展（2026-10-15，源码版本 0.2.0）

本次仅修改独立插件仓库，宿主 dotfiles 与真实 Mihomo 服务未改动。`tests/profiles_test.lua` 通过 mock 验证本地绝对路径传入 argv、导入不启用、已知 ID 切换、回退结果、超时与迟到回调；`tests/ui_test.lua` 验证离线配置列表、导入与切换按钮及分页。原有 `tests/service_test.lua` 仍通过。`noctalia plugins lint .` 返回 0 errors、0 warnings；JSON/TOML 解析与 `git diff --check` 通过。这些是源码和 mock 层验证，并未证明宿主适配器、真实 YAML、权限桥或服务切换可用。端到端验收须在宿主实现[配置管理适配器协议](profile-helper.md)后进行。
