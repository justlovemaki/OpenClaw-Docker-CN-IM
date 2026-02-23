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

# 安装 OpenClaw 汉化版和 OpenCode AI
RUN npm install -g @qingchencloud/openclaw-zh@latest opencode-ai@latest

# 去除汉化版品牌推广 (纯 sed 实现)
# 1) 删除注入的功能面板  2) 隐藏导航栏推广链接  3) 清理品牌文字
RUN ASSETS_DIR="/usr/local/lib/node_modules/@qingchencloud/openclaw-zh/dist/control-ui/assets" && \
    MAIN_JS=$(ls ${ASSETS_DIR}/index-*.js 2>/dev/null | grep -v '.map' | head -1) && \
    MAIN_CSS=$(ls ${ASSETS_DIR}/index-*.css 2>/dev/null | head -1) && \
    if [ -n "$MAIN_JS" ]; then \
      sed -i '/\/\* === OpenClaw 功能面板 === \*\//,$d' "$MAIN_JS" && \
      sed -i 's|style="color: #f59e0b; font-weight: 600;"|style="display:none!important"|' "$MAIN_JS" && \
      sed -i 's|style="color: #ef4444;"|style="display:none!important"|' "$MAIN_JS" && \
      sed -i 's|href="https://github.com/1186258278/OpenClawChineseTranslation"|href="#" style="display:none!important"|' "$MAIN_JS" && \
      sed -i 's|href="https://openclaw.qt.cool" target="_blank" rel="noreferrer" title="访问 OpenClaw 汉化官网" style="text-decoration: none; color: inherit;"|href="/"|' "$MAIN_JS" && \
      sed -i 's|OPENCLAW 中文版|OPENCLAW|g' "$MAIN_JS" && \
      sed -i 's|网关控制台 · 点击访问官网|网关控制台|g' "$MAIN_JS" && \
      echo "Cleaned JS: $(basename $MAIN_JS)"; \
    fi && \
    if [ -n "$MAIN_CSS" ]; then \
      sed -i '/\/\* === OpenClaw 功能面板样式 === \*\//,$d' "$MAIN_CSS" && \
      echo "Cleaned CSS: $(basename $MAIN_CSS)"; \
    fi

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
RUN mkdir -p /home/node/.openclaw/extensions && \
    cd /home/node/.openclaw/extensions && \
    git clone https://github.com/soimy/openclaw-channel-dingtalk.git && \
    cd openclaw-channel-dingtalk && \
    npm install && \
    timeout 300 openclaw plugins install -l . || true

# 安装 QQ 机器人插件 - 使用 timeout 防止卡住，忽略错误继续构建
RUN cd /tmp && \
    git clone https://github.com/justlovemaki/qqbot.git && \
    cd qqbot && \
    timeout 300 openclaw plugins install . || true

# 安装企业微信插件 (@sunnoy/wecom) - 使用 timeout 防止卡住，忽略错误继续构建
RUN timeout 300 openclaw plugins install @sunnoy/wecom || true

# 安装企业微信应用号插件 (openclaw-wechat) - 使用 timeout 防止卡住，忽略错误继续构建
# 注意: 原始插件 channel ID 为 "wecom"，与 @sunnoy/wecom 冲突，
#       通过 sed 改为 "wecom-app" 实现共存
RUN mkdir -p /home/node/.openclaw/extensions && \
    cd /home/node/.openclaw/extensions && \
    git clone https://github.com/Xueheng-Li/openclaw-wechat.git && \
    cd openclaw-wechat && \
    # 修改 channel ID: wecom -> wecom-app (避免与 @sunnoy/wecom 冲突)
    sed -i 's/"channels": \["wecom"\]/"channels": ["wecom-app"]/g' openclaw.plugin.json && \
    sed -i 's/"id": "wecom"/"id": "wecom-app"/g' clawdbot.plugin.json package.json && \
    sed -i 's/channels?\.wecom/channels?.["wecom-app"]/g' src/index.js && \
    sed -i 's/id: "wecom"/id: "wecom-app"/g' src/index.js && \
    npm install && \
    timeout 300 openclaw plugins install -l . || true

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
