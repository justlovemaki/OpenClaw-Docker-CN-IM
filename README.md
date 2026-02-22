# OpenClaw-Docker-CN-IM

> 🚀 **推荐搭配**：OpenClaw 功能强大但 Token 消耗较大，推荐配合 [AIClient-2-API](https://github.com/justlovemaki/AIClient-2-API) 项目使用，将各大 AI 客户端转换为标准 API 接口，实现无限 Token 调用，彻底解决 Token 焦虑！本项目已支持 OpenAI 和 Claude 两种协议，可直接对接 AIClient-2-API 服务。

## 项目简介

OpenClaw 中国 IM 插件整合版 Docker 镜像，预装并配置了飞书、钉钉、QQ机器人、企业微信等主流中国 IM 平台插件，让您可以快速部署一个支持多个中国 IM 平台的 AI 机器人网关。

**项目地址**: https://github.com/justlovemaki/OpenClaw-Docker-CN-IM

### 核心特性

- 🚀 **开箱即用**：预装所有中国主流 IM 平台插件
- 🔧 **灵活配置**：通过环境变量轻松配置各平台凭证
- 🐳 **Docker 部署**：一键启动，无需复杂配置
- 📦 **数据持久化**：支持配置和工作空间数据持久化
- 💻 **OpenCode AI**：内置 AI 代码助手，支持智能代码生成和分析
- 🎭 **Playwright**：预装浏览器自动化工具，支持网页操作和截图
- 🗣️ **中文 TTS**：支持中文语音合成（Text-to-Speech）

### 支持的平台

**IM 平台**
- ✅ 飞书（Feishu/Lark）
- ✅ 钉钉（DingTalk）
- ✅ QQ 机器人（QQ Bot）
- ✅ 企业微信（WeCom）

**集成工具**
- ✅ OpenCode AI - AI 代码助手
- ✅ Playwright - 浏览器自动化
- ✅ 中文 TTS - 语音合成

### Docker 镜像地址

**Docker Hub**: https://hub.docker.com/r/justlikemaki/openclaw-docker-cn-im

```bash
docker pull justlikemaki/openclaw-docker-cn-im:latest
```

---

## 快速开始

### 方式一：使用预构建镜像（推荐）

#### 1. 下载配置文件

```bash
wget https://raw.githubusercontent.com/justlovemaki/OpenClaw-Docker-CN-IM/main/docker-compose.yml
wget https://raw.githubusercontent.com/justlovemaki/OpenClaw-Docker-CN-IM/main/.env.example
```

#### 2. 配置环境变量

```bash
# 复制环境变量模板
cp .env.example .env

# 编辑配置文件（至少配置 AI 模型相关参数）
nano .env
```

**最小配置示例**：

| 环境变量 | 说明 | 示例值 |
|---------|------|--------|
| `MODEL_ID` | AI 模型名称 | `gpt-4` |
| `BASE_URL` | AI 服务 API 地址 | `https://api.openai.com/v1` |
| `API_KEY` | AI 服务 API 密钥 | `sk-xxx...` |

> 💡 **提示**：IM 平台配置为可选项，可以先启动服务，后续再配置需要的平台。

#### 3. 启动服务

```bash
docker-compose up -d
```

#### 4. 查看日志

```bash
docker-compose logs -f
```

#### 5. 停止服务

```bash
docker-compose down
```

#### 6. 进入容器

如需进入容器进行调试或执行命令：

```bash
# 使用 docker-compose 进入容器
docker-compose exec openclaw-gateway /bin/bash

# 或使用 docker 命令进入容器
docker exec -it openclaw-gateway /bin/bash
```

进入容器后，可以执行以下常用命令：

```bash
# 查看 OpenClaw 版本
openclaw --version

# 查看配置文件
cat ~/.openclaw/openclaw.json

# 查看工作空间
ls -la ~/.openclaw/workspace

# 手动执行配对命令（如 Telegram）
openclaw pairing approve telegram {token}
```

### 方式二：自行构建镜像

如果您需要自定义镜像或进行开发调试，可以选择自行构建：

#### 1. 克隆项目

```bash
git clone https://github.com/justlovemaki/OpenClaw-Docker-CN-IM.git
cd OpenClaw-Docker-CN-IM
```

#### 2. 构建镜像

```bash
docker build -t justlikemaki/openclaw-docker-cn-im:latest .
```

#### 3. 配置环境变量

```bash
# 复制环境变量模板
cp .env.example .env

# 编辑配置文件（至少配置 AI 模型相关参数）
nano .env
```

#### 4. 启动服务

```bash
docker-compose up -d
```

---

## 配置指南

### AI 模型配置

本项目支持 **OpenAI 协议**和 **Claude 协议**两种 API 格式。

> 💡 **推荐模型**：推荐使用 `gemini-3-flash-preview` 模型，该模型具有超大上下文窗口（1M tokens）、快速响应速度和优秀的性价比，非常适合作为 OpenClaw 的后端模型。

#### 基础配置参数

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `MODEL_ID` | 模型名称 | `model id` |
| `BASE_URL` | Provider Base URL | `http://xxxxx/v1` |
| `API_KEY` | Provider API Key | `123456` |
| `API_PROTOCOL` | API 协议类型 | `openai-completions` |
| `CONTEXT_WINDOW` | 模型上下文窗口大小 | `200000` |
| `MAX_TOKENS` | 模型最大输出 tokens | `8192` |

#### 协议类型说明

| 协议类型 | 适用模型 | Base URL 格式 | 特殊特性 |
|---------|---------|--------------|---------|
| `openai-completions` | OpenAI、Gemini 等 | 需要 `/v1` 后缀 | - |
| `anthropic-messages` | Claude | 不需要 `/v1` 后缀 | Prompt Caching、Extended Thinking |

#### 配置示例

**OpenAI 协议（Gemini 模型）**

```bash
MODEL_ID=gemini-3-flash-preview
BASE_URL=http://localhost:3000/v1
API_KEY=your-api-key
API_PROTOCOL=openai-completions
CONTEXT_WINDOW=1000000
MAX_TOKENS=8192
```

**Claude 协议（Claude 模型）**

```bash
MODEL_ID=claude-sonnet-4-5
BASE_URL=http://localhost:3000
API_KEY=your-api-key
API_PROTOCOL=anthropic-messages
CONTEXT_WINDOW=200000
MAX_TOKENS=8192
```

### Gateway 配置

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `OPENCLAW_GATEWAY_TOKEN` | Gateway 访问令牌 | `123456` |
| `OPENCLAW_GATEWAY_BIND` | 绑定地址 | `lan` |
| `OPENCLAW_GATEWAY_PORT` | Gateway 端口 | `18789` |
| `OPENCLAW_BRIDGE_PORT` | Bridge 端口 | `18790` |

### 工作空间配置

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `WORKSPACE` | 工作空间目录 | `/home/node/.openclaw/workspace` |

---

## 常见问题

### Q: 修改了环境变量但配置没有生效？

容器启动时只有在配置文件不存在时才会生成新配置。如需重新生成配置，请删除现有配置文件：

```bash
# 删除配置文件
rm ~/.openclaw/openclaw.json
# 重启容器
docker-compose restart
```

或者直接删除整个数据目录重新开始：

```bash
rm -rf ~/.openclaw
docker-compose up -d
```

### Q: 连接 AIClient-2-API 失败？

- 确认 AIClient-2-API 服务运行中
- 检查 Base URL 是否正确（OpenAI 协议需要 `/v1` 后缀）
- 尝试使用 `127.0.0.1` 替代 `localhost`

### Q: 401 错误？

- 检查 API Key 是否正确配置
- 确认环境变量 `API_KEY` 已设置

### Q: 模型不可用？

- 在 AIClient-2-API Web UI 确认已配置对应提供商
- 重启容器：`docker-compose restart`

### Q: 飞书机器人能发消息但收不到消息？

- 检查是否配置了事件订阅（最容易遗漏的配置）
- 确认事件配置方式选择了"使用长连接接收事件"
- 确认已添加 `im.message.receive_v1` 事件

### Q: Telegram 机器人如何配对？

如果需要启用 Telegram，必须提供有效的 `TELEGRAM_BOT_TOKEN`，启用后需要执行以下命令进行配对审批：

```bash
openclaw pairing approve telegram {token}
```

并且需要重启 Docker 服务使配置生效。

### Q: 同样的启动命令，为什么有人报错 `Permission denied`？

这通常不是命令本身不稳定，而是**运行上下文变化**导致：宿主机挂载目录所有者（UID/GID）与容器内进程用户不一致。

#### 为什么会“偶发”

- 同样是 `docker compose up -d`，但目录来源不同：
  - 你手动创建目录：可能是当前用户（如 `1000:1000`）
  - Docker 自动创建或使用 sudo 创建：可能是 `root:root`（`0:0`）
- 本镜像最终以 `node` 用户运行网关；若挂载目录归属不匹配，就可能无法写入。

#### 快速排查

```bash
# 1) 看宿主机目录归属（Linux）
ls -ln ~/.openclaw

# 2) 看容器内运行用户
docker run --rm justlikemaki/openclaw-docker-cn-im:latest id
```

若容器用户是 `uid=1000`，而宿主机目录是 `uid=0` 且权限不足，就会报错。

#### 解决方案（推荐顺序）

1. **宿主机修正目录所有权（最直接）**

```bash
sudo chown -R 1000:1000 ~/.openclaw
```

2. **显式指定容器运行用户（可选）**

在 `.env` 中设置：

```bash
OPENCLAW_RUN_USER=1000:1000
```

然后重启：

```bash
docker compose up -d
```

3. **SELinux 场景（CentOS/RHEL/Fedora）**

若权限看起来没问题但仍拒绝访问，请给挂载卷加 `:z` 或 `:Z` 标签。

#### 本项目已做的稳态处理

- [`docker-compose.yml`](docker-compose.yml) 新增可选 `user` 配置：`OPENCLAW_RUN_USER`（默认 `0:0`）
- [`init.sh`](init.sh) 启动时会：
  - 打印挂载目录当前 UID/GID 与目标 UID/GID
  - 尝试自动修复 `/home/node/.openclaw` 权限
  - 若仍不可写，输出明确的修复命令并失败退出，避免“有时成功有时报错”的隐性状态
---

## 注意事项

1. 确保宿主机的 18789 和 18790 端口未被占用
2. 配置文件中的敏感信息（如 API 密钥、令牌）应妥善保管
3. 首次运行时会自动创建必要的目录和配置文件，包括 `openclaw.json` 配置文件，已存在时不会覆盖
4. 容器以 `node` 用户身份运行，确保挂载的卷有正确的权限
5. IM 平台配置均为可选项，可根据实际需求选择性配置
6. 使用 OpenAI 协议时，Base URL 需要包含 `/v1` 后缀
7. 使用 Claude 协议时，Base URL 不需要 `/v1` 后缀

---

## IM 平台配置

<details>
<summary><b>飞书配置</b></summary>

### 1. 获取飞书机器人凭证

1. 在 [飞书开放平台](https://open.feishu.cn/) 创建自建应用
2. 添加应用能力-机器人
3. 在凭证页面获取 **App ID** 和 **App Secret**
4. 开启所需权限（见下方）⚠️ **重要**
5. 配置事件订阅（见下方）⚠️ **重要**

### 2. 必需权限（租户级别）

| 权限 | 范围 | 说明 |
|------|------|------|
| `im:message` | 消息 | 发送和接收消息（核心权限） |
| `im:message.p2p_msg:readonly` | 私聊 | 读取发给机器人的私聊消息 |
| `im:message.group_at_msg:readonly` | 群聊 | 接收群内 @机器人 的消息 |
| `im:message:send_as_bot` | 发送 | 以机器人身份发送消息 |
| `im:resource` | 媒体 | 上传和下载图片/文件 |
| `im:chat.members:bot_access` | 群成员 | 获取群成员信息 |
| `im:chat.access_event.bot_p2p_chat:read` | 聊天事件 | 读取机器人单聊事件 |

### 3. 推荐权限（租户级别）

| 权限 | 范围 | 说明 |
|------|------|------|
| `contact:user.employee_id:readonly` | 用户信息 | 获取用户员工 ID（用于用户识别） |
| `im:message:readonly` | 读取 | 获取历史消息 |
| `application:application:self_manage` | 应用管理 | 应用自我管理 |
| `application:bot.menu:write` | 机器人菜单 | 配置机器人菜单 |
| `event:ip_list` | IP 列表 | 获取飞书服务器 IP 列表 |

### 4. 可选权限（租户级别）

| 权限 | 范围 | 说明 |
|------|------|------|
| `aily:file:read` | AI 文件读取 | 读取 AI 助手文件 |
| `aily:file:write` | AI 文件写入 | 写入 AI 助手文件 |
| `application:application.app_message_stats.overview:readonly` | 消息统计 | 查看应用消息统计概览 |
| `corehr:file:download` | 人事文件 | 下载人事系统文件 |

### 5. 用户级别权限（可选）

| 权限 | 范围 | 说明 |
|------|------|------|
| `aily:file:read` | AI 文件读取 | 以用户身份读取 AI 助手文件 |
| `aily:file:write` | AI 文件写入 | 以用户身份写入 AI 助手文件 |
| `im:chat.access_event.bot_p2p_chat:read` | 聊天事件 | 以用户身份读取机器人单聊事件 |

### 6. 事件订阅 ⚠️

**这是最容易遗漏的配置！** 如果机器人能发消息但收不到消息，请检查此项。

在飞书开放平台的应用后台，进入 **事件与回调** 页面：

1. **事件配置方式**：选择 **使用长连接接收事件**（推荐）
2. **添加事件订阅**，勾选以下事件：

| 事件 | 说明 |
|------|------|
| `im.message.receive_v1` | 接收消息（必需） |
| `im.message.message_read_v1` | 消息已读回执 |
| `im.chat.member.bot.added_v1` | 机器人进群 |
| `im.chat.member.bot.deleted_v1` | 机器人被移出群 |

3. 确保事件订阅的权限已申请并通过审核

### 7. 环境变量配置

在 `.env` 文件中添加：

```bash
FEISHU_APP_ID=your-app-id
FEISHU_APP_SECRET=your-app-secret
```

> 💡 **参考项目**：[clawdbot-feishu](https://github.com/openclaw/openclaw/blob/main/docs/channels/feishu.md) - 飞书机器人完整实现示例

</details>

<details>
<summary><b>钉钉配置</b></summary>

### 1. 创建钉钉应用

1. 访问 [钉钉开发者后台](https://open-dev.dingtalk.com/)
2. 创建企业内部应用
3. 添加「机器人」能力
4. 配置消息接收模式为 **Stream 模式**
5. 发布应用

### 2. 获取凭证

从开发者后台获取：

- **Client ID**（AppKey）
- **Client Secret**（AppSecret）
- **Robot Code**（与 Client ID 相同）
- **Corp ID**（与 Client ID 相同）
- **Agent ID**（应用 ID）

### 3. 环境变量配置

在 `.env` 文件中添加：

```bash
DINGTALK_CLIENT_ID=your-dingtalk-client-id
DINGTALK_CLIENT_SECRET=your-dingtalk-client-secret
DINGTALK_ROBOT_CODE=your-dingtalk-robot-code
DINGTALK_CORP_ID=your-dingtalk-corp-id
DINGTALK_AGENT_ID=your-dingtalk-agent-id
```

**参数说明**：
- `DINGTALK_CLIENT_ID` - 必需，钉钉应用的 Client ID（AppKey）
- `DINGTALK_CLIENT_SECRET` - 必需，钉钉应用的 Client Secret（AppSecret）
- `DINGTALK_ROBOT_CODE` - 可选，机器人 Code，默认与 Client ID 相同
- `DINGTALK_CORP_ID` - 可选，企业 ID
- `DINGTALK_AGENT_ID` - 可选，应用 Agent ID

> 💡 **参考项目**：[openclaw-channel-dingtalk](https://github.com/soimy/openclaw-channel-dingtalk) - 钉钉渠道完整实现示例

</details>

<details>
<summary><b>QQ 机器人配置</b></summary>

### 1. 获取 QQ 机器人凭证

1. 访问 [QQ 开放平台](https://q.qq.com/)
2. 创建机器人应用
3. 获取 AppID 和 AppSecret（ClientSecret）
4. 获取主机在公网的 IP，配置到 IP 白名单

### 2. 环境变量配置

在 `.env` 文件中添加：

```bash
QQBOT_APP_ID=你的AppID
QQBOT_CLIENT_SECRET=你的AppSecret
```

> 💡 **参考项目**：[qqbot](https://github.com/sliverp/qqbot) - QQ 机器人完整实现示例

</details>

<details>
<summary><b>企业微信配置</b></summary>

### 1. 获取企业微信凭证

1. 访问 [企业微信管理后台-安全与管理-管理工具](https://work.weixin.qq.com/wework_admin/frame#/manageTools)
2. 进入"智能专区" - 用 API 模式创建"智能机器人"应用
3. 在应用的"接收消息"配置中设置 Token 和 EncodingAESKey
4. 设置"接收消息"URL 为你的服务地址（例如： https://your-domain.com/webhooks/wecom ），需要当前服务可公网访问

### 2. 环境变量配置

在 `.env` 文件中添加：

```bash
WECOM_TOKEN=your-token
WECOM_ENCODING_AES_KEY=your-aes-key
```

> 💡 **参考项目**：[openclaw-plugin-wecom](https://github.com/sunnoy/openclaw-plugin-wecom) - 企业微信插件完整实现示例

</details>

---

## AIClient-2-API 配置指南

<details>
<summary><b>点击展开 AIClient-2-API 配置说明</b></summary>

本项目已支持 OpenAI 和 Claude 两种协议，可直接对接 [AIClient-2-API](https://github.com/justlovemaki/AIClient-2-API) 服务。

### 前置准备

1. 启动 AIClient-2-API 服务
2. 在 Web UI (`http://localhost:3000`) 配置至少一个提供商
3. 记录配置文件中的 API Key

### 配置方式一：OpenAI 协议（推荐用于 Gemini）

在 `.env` 文件中配置：

```bash
MODEL_ID=gemini-3-flash-preview
BASE_URL=http://localhost:3000/v1
API_KEY=your-api-key
API_PROTOCOL=openai-completions
CONTEXT_WINDOW=1000000
MAX_TOKENS=8192
```

### 配置方式二：Claude 协议（推荐用于 Claude）

在 `.env` 文件中配置：

```bash
MODEL_ID=claude-sonnet-4-5
BASE_URL=http://localhost:3000
API_KEY=your-api-key
API_PROTOCOL=anthropic-messages
CONTEXT_WINDOW=200000
MAX_TOKENS=8192
```

### 指定特定提供商（可选）

如需指定特定提供商，可修改 Base URL：

```bash
# Kiro 提供的 Claude (OpenAI 协议)
BASE_URL=http://localhost:3000/claude-kiro-oauth/v1

# Kiro 提供的 Claude (Claude 协议)
BASE_URL=http://localhost:3000/claude-kiro-oauth

# Gemini CLI (OpenAI 协议)
BASE_URL=http://localhost:3000/gemini-cli-oauth/v1

# Antigravity (OpenAI 协议)
BASE_URL=http://localhost:3000/gemini-antigravity/v1
```

</details>

---

## 高级使用

<details>
<summary><b>使用 Docker 命令运行</b></summary>

如果不使用 Docker Compose，可以直接使用 Docker 命令：

```bash
docker run -d \
  --name openclaw-gateway \
  --cap-add=CHOWN \
  --cap-add=SETUID \
  --cap-add=SETGID \
  --cap-add=DAC_OVERRIDE \
  -e MODEL_ID=model id \
  -e BASE_URL=http://xxxxx/v1 \
  -e API_KEY=123456 \
  -e API_PROTOCOL=openai-completions \
  -e CONTEXT_WINDOW=200000 \
  -e MAX_TOKENS=8192 \
  -e FEISHU_APP_ID=your-app-id \
  -e FEISHU_APP_SECRET=your-app-secret \
  -e DINGTALK_CLIENT_ID=your-dingtalk-client-id \
  -e DINGTALK_CLIENT_SECRET=your-dingtalk-client-secret \
  -e DINGTALK_ROBOT_CODE=your-dingtalk-robot-code \
  -e DINGTALK_CORP_ID=your-dingtalk-corp-id \
  -e DINGTALK_AGENT_ID=your-dingtalk-agent-id \
  -e QQBOT_APP_ID=your-qqbot-app-id \
  -e QQBOT_CLIENT_SECRET=your-qqbot-client-secret \
  -e WECOM_TOKEN=your-token \
  -e WECOM_ENCODING_AES_KEY=your-aes-key \
  -e OPENCLAW_GATEWAY_TOKEN=123456 \
  -e OPENCLAW_GATEWAY_BIND=lan \
  -e OPENCLAW_GATEWAY_PORT=18789 \
  -v ~/.openclaw:/home/node/.openclaw \
  -v ~/.openclaw/workspace:/home/node/.openclaw/workspace \
  -p 18789:18789 \
  -p 18790:18790 \
  --restart unless-stopped \
  justlikemaki/openclaw-docker-cn-im:latest
```

</details>

<details>
<summary><b>数据持久化</b></summary>

容器使用以下卷进行数据持久化：

- `/home/node/.openclaw` - OpenClaw 配置和数据目录
- `/home/node/.openclaw/workspace` - 工作空间目录

</details>

<details>
<summary><b>端口说明</b></summary>

- `18789` - OpenClaw Gateway 端口
- `18790` - OpenClaw Bridge 端口

</details>

<details>
<summary><b>自定义配置文件</b></summary>

如果需要完全自定义配置文件，可以：

1. 在宿主机创建配置文件 `~/.openclaw/openclaw.json`
2. 挂载该目录到容器：`-v ~/.openclaw:/home/node/.openclaw`
3. 容器启动时会检测到已存在的配置文件，跳过自动生成

</details>

---

## 开发者信息

<details>
<summary><b>项目文件说明</b></summary>

- [`Dockerfile`](Dockerfile) - Docker 镜像构建文件
- [`init.sh`](init.sh) - 容器初始化脚本（作为主程序运行）
- [`docker-compose.yml`](docker-compose.yml) - Docker Compose 配置文件
- [`.env.example`](.env.example) - 环境变量配置模板
- [`.dockerignore`](.dockerignore) - Docker 构建忽略文件
- [`openclaw.json.example`](openclaw.json.example) - OpenClaw 默认配置文件示例

</details>

<details>
<summary><b>构建镜像</b></summary>

```bash
docker build -t justlikemaki/openclaw-docker-cn-im:latest .
```

</details>

<details>
<summary><b>初始化脚本功能</b></summary>

[`init.sh`](init.sh) 脚本在容器启动时执行以下操作：

1. 创建必要的目录结构
2. 根据环境变量动态生成配置文件（如果不存在）
3. 设置正确的文件权限
4. 启动 OpenClaw Gateway 服务（verbose 模式）

</details>

<details>
<summary><b>配置文件生成</b></summary>

容器首次启动时，如果 `/home/node/.openclaw/openclaw.json` 不存在，初始化脚本会根据环境变量自动生成配置文件，包括：

- **模型配置**：使用指定的模型和 Provider
- **通道配置**：根据提供的环境变量启用相应的 IM 平台
- **Gateway 配置**：端口、绑定地址、认证令牌
- **插件配置**：自动启用相应的通道插件

</details>

<details>
<summary><b>安装的包</b></summary>

镜像中已全局安装以下 npm 包：

- `openclaw@latest` - OpenClaw 主程序
- `opencode-ai@latest` - OpenCode AI
- `playwright` - Playwright 浏览器自动化工具
- `@openclaw/feishu` - 飞书插件
- `clawdbot-channel-dingtalk` - 钉钉插件（从 GitHub 安装）
- `qqbot` - QQ 机器人插件（先克隆到 `/tmp/qqbot`，然后从本地目录安装）
- `openclaw-plugin-wecom` - 企业微信插件（从 GitHub 安装）

</details>

<details>
<summary><b>启动命令</b></summary>

容器使用以下命令启动 OpenClaw：

```bash
openclaw gateway --verbose
```

这将以详细日志模式启动 Gateway 服务。

</details>

---

## ⭐ Star History

如果这个项目对您有帮助，请给我们一个 Star ⭐️！您的支持是我们持续改进的动力。

[![Star History Chart](https://api.star-history.com/svg?repos=justlovemaki/OpenClaw-Docker-CN-IM&type=Date)](https://star-history.com/#justlovemaki/OpenClaw-Docker-CN-IM&Date)

---

## 💖 赞助支持

如果您觉得这个项目对您有帮助，欢迎赞助支持我们的开发工作！

<p align="center">
  <img src="sponsor.png" alt="微信赞赏码" width="300">
</p>

### 赞助者名单

感谢以下赞助者的支持：

赞助者列表将在这里更新

---

## 许可证

本项目基于 OpenClaw 构建，遵循 GNU General Public License v3.0 (GPL-3.0) 许可证。详见 [`LICENSE`](LICENSE) 文件。
