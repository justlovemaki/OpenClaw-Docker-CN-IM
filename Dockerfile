# OpenClaw Docker 镜像
FROM node:22-slim

# 设置工作目录
WORKDIR /app

# 安装必要的系统依赖
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    chromium \
    curl \
    fonts-liberation \
    fonts-noto-cjk \
    fonts-noto-color-emoji \
    git \
    gosu \
    jq \
    python3 \
    socat \
    tini \
    unzip \
    websockify \
  && rm -rf /var/lib/apt/lists/*

# 更新 npm 到最新版本
RUN npm install -g npm@latest

# 安装 bun
RUN curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash
ENV BUN_INSTALL="/usr/local"
ENV PATH="$BUN_INSTALL/bin:$PATH"

# 安装 qmd
RUN bun install -g https://github.com/tobi/qmd

# 安装 OpenClaw 和 OpenCode AI
RUN npm install -g openclaw@2026.2.13 opencode-ai@latest

# 安装 Playwright 和 Chromium
RUN npm install -g playwright && npx playwright install chromium --with-deps

# 安装 playwright-extra 和 puppeteer-extra-plugin-stealth
RUN npm install -g playwright-extra puppeteer-extra-plugin-stealth

# 安装 bird
RUN npm install -g @steipete/bird

# 创建配置目录并设置权限
RUN mkdir -p /home/node/.openclaw/workspace && \
    chown -R node:node /home/node

# 切换到 node 用户安装插件
USER node

# OpenClaw已内置飞书插件 - 使用 timeout 防止卡住，忽略错误继续构建
# RUN timeout 300 openclaw plugins install @m1heng-clawd/feishu || true

# 安装钉钉插件 - 使用 timeout 防止卡住，忽略错误继续构建
RUN timeout 300 openclaw plugins install https://github.com/soimy/clawdbot-channel-dingtalk.git || true

# 安装 QQ 机器人插件 - 使用 timeout 防止卡住，忽略错误继续构建
RUN cd /tmp && \
    git clone https://github.com/justlovemaki/qqbot.git && \
    cd qqbot && \
    timeout 300 openclaw plugins install . || true

# 安装企业微信插件 - 使用 timeout 防止卡住，忽略错误继续构建
RUN timeout 300 openclaw plugins install @sunnoy/wecom || true

# 切换回 root 用户继续后续操作
USER root

# 如果存在，删除飞书插件目录（OpenClaw 已内置）
RUN rm -rf /home/node/.openclaw/extensions/feishu

# 确保 extensions 目录权限正确（排除 node_modules 以加快构建速度）
RUN if [ -d /home/node/.openclaw/extensions ]; then find /home/node/.openclaw/extensions -type d -name node_modules -prune -o -exec chown node:node {} +; fi

# 复制初始化脚本
COPY ./init.sh /usr/local/bin/init.sh
RUN chmod +x /usr/local/bin/init.sh

# 设置基础环境变量
ENV HOME=/home/node \
    TERM=xterm-256color \
    NODE_PATH=/usr/local/lib/node_modules

# 暴露端口
EXPOSE 18789 18790

# 设置工作目录为 home
WORKDIR /home/node

# 使用初始化脚本作为入口点（以 root 运行以便修复权限）
ENTRYPOINT ["/bin/bash", "/usr/local/bin/init.sh"]
