# 项目协作指南

本仓库发布可复用的 Noctalia v5 插件。`mihomo-control/service.luau` 处理本机 Mihomo API 与可选宿主适配器，`panel.luau` 和 `widget.luau` 只负责界面及命令；各 entry 通过 `noctalia.state` 传递普通值。插件 ID 是 `nmc/mihomo-control`，最低 `plugin_api` 由 `plugin.toml` 声明。

开始修改前执行 `git status --short` 并阅读 [README](README.md)。保留无关改动；源码、文档、测试数据和历史不得加入真实订阅、令牌、账户、主机路径或部署端点。插件只连接 loopback 控制器，不提权、不假定服务管理器。配置文件的持久化、校验、切换和回退属于宿主适配器；协议见[配置适配器](docs/profile-helper.md)。

验证命令：

```sh
noctalia plugins lint .
lua tests/service_test.lua
lua tests/profiles_test.lua
lua tests/ui_test.lua
git diff --check
```

mock 测试和 lint 不能证明真实配置切换。修改 service 或 panel 后检查离线界面与实际 Noctalia 加载；涉及宿主适配器的行为只在独立部署环境完成端到端验收。行为、测试、文档分别使用中文描述的 Conventional Commits 提交。
