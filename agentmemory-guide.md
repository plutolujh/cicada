# agentmemory 使用指南

agentmemory 是一个给 AI 编程 agent（Claude Code、Codex、Cursor 等）用的「持久化记忆」引擎。底层基于 `iii` 进程通信引擎，让 agent 在跨会话时「记住」之前做过的事，不用每轮重新解释架构、bug、偏好。

## 本机现状（2026-11-05 更新）

- **agentmemory**：`v0.9.32`（全局安装于 `/opt/homebrew/bin/agentmemory`），服务运行中，健康状态 `healthy`
- **iii 引擎**：daemon 使用 `~/.agentmemory/bin/iii`（v0.25.0，agentmemory 0.9.32 自动下载）；系统另有 `/Users/java/.local/bin/iii`（v0.11.2）
- **数据目录**：`~/Library/Application Support/agentmemory/` → `state_store.db`（状态）、`stream_store`（流式存储）；secret 在 `~/.agentmemory/secret`
- **端口**：
  - REST API：`http://localhost:3111`（需要 `Authorization: Bearer <~/.agentmemory/secret>`）
  - Viewer：`http://localhost:3113`
  - Engine：`ws://localhost:49134`
- **LLM**：已启用 `AGENTMEMORY_LLM_PROVIDER=minimax`（配置在 `~/.agentmemory/.env` 与 `~/Library/Application Support/agentmemory/compose/.agentmemory-filtered.env`）

## 安装

```bash
npm install -g @agentmemory/agentmemory
```

## 基本使用

```bash
agentmemory                    # 启动记忆服务器
agentmemory stop               # 停止
agentmemory remove             # 卸载全部
agentmemory doctor             # 交互式诊断 + 修复提示
agentmemory upgrade            # 升级（会拉取钉死的 iii v0.11.2，不会装更新的 iii）
```

## 常用操作

```bash
agentmemory demo               # 灌 3 个示例会话 + 演示语义召回
agentmemory import-jsonl      # 导入 Claude Code 历史 JSONL（默认 ~/.claude/projects）
agentmemory import-jsonl ~/.claude/projects/-my-project/abc123.jsonl   # 导入单个文件
agentmemory connect claude-code  # 给 Claude Code 接上 MCP
agentmemory connect codex
agentmemory connect cursor
```

## 给 Claude Code 接上（推荐方式）

```bash
agentmemory                      # 先启动服务器
/plugin marketplace add rohitg00/agentmemory
/plugin install agentmemory
```

装完插件后，agent 会拿到 53 个 MCP 工具（`memory_smart_search`、`memory_save`、`memory_sessions`、`memory_governance_delete` 等）和 12 个自动 hook。会话中的对话/工具调用会被自动捕获、压缩成可检索的记忆，下一轮会话自动注入相关上下文。

- 验证：`curl http://localhost:3111/agentmemory/health`
- 实时看记忆：`http://localhost:3113`

## REST API（不用 MCP 也能调）

```bash
curl http://localhost:3111/agentmemory/health
curl -X POST http://localhost:3111/agentmemory/smart-search -d '{"query":"auth"}'
```

## 重要注意事项

- **iii 版本**：agentmemory 0.9.32 在本机自动下载并使用了 `~/.agentmemory/bin/iii` v0.25.0。README 曾说明 agentmemory 钉死 iii-engine v0.11.2（0.11.6+ 引入 sandbox 模型）；若后续遇到不兼容，可尝试 `AGENTMEMORY_III_VERSION=0.11.2` 或回退 agentmemory 版本。
- **认证**：REST API 需要 `Authorization: Bearer <secret>`，secret 位于 `~/.agentmemory/secret`。示例：`curl -H "Authorization: Bearer $(tr -d '\n' < ~/.agentmemory/secret)" http://localhost:3111/agentmemory/health`
- **升级**：升级前确认 agentmemory/iii 的发布源和升级方式，避免只替换二进制导致配置不兼容。升级后运行 `agentmemory doctor` 检查。