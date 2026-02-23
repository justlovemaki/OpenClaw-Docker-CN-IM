#!/bin/bash

set -e

echo "=== OpenClaw 初始化脚本 ==="

OPENCLAW_HOME="/home/node/.openclaw"
OPENCLAW_WORKSPACE="${WORKSPACE:-/home/node/.openclaw/workspace}"
NODE_UID="$(id -u node)"
NODE_GID="$(id -g node)"

# 创建必要目录
mkdir -p "$OPENCLAW_HOME" "$OPENCLAW_WORKSPACE"

# 预检查挂载卷权限（避免同样命令偶发 Permission denied）
if [ "$(id -u)" -eq 0 ]; then
    CURRENT_OWNER="$(stat -c '%u:%g' "$OPENCLAW_HOME" 2>/dev/null || echo unknown:unknown)"
    echo "挂载目录: $OPENCLAW_HOME"
    echo "当前所有者(UID:GID): $CURRENT_OWNER"
    echo "目标所有者(UID:GID): ${NODE_UID}:${NODE_GID}"

    if [ "$CURRENT_OWNER" != "${NODE_UID}:${NODE_GID}" ]; then
        echo "检测到宿主机挂载目录所有者与容器运行用户不一致，尝试自动修复..."
        chown -R node:node "$OPENCLAW_HOME" || true
    fi

    # 再次验证写权限，失败则给出明确诊断
    if ! gosu node test -w "$OPENCLAW_HOME"; then
        echo "❌ 权限检查失败：node 用户无法写入 $OPENCLAW_HOME"
        echo "请在宿主机执行（Linux）："
        echo "  sudo chown -R ${NODE_UID}:${NODE_GID} <your-openclaw-data-dir>"
        echo "或在启动时显式指定用户："
        echo "  docker run --user \$(id -u):\$(id -g) ..."
        echo "若宿主机启用了 SELinux，请在挂载卷后添加 :z 或 :Z"
        exit 1
    fi
fi

# 全量同步配置逻辑
sync_config_with_env() {
    local config_file="/home/node/.openclaw/openclaw.json"
    
    # 如果文件不存在，创建一个基础骨架
    if [ ! -f "$config_file" ]; then
        echo "配置文件不存在，创建基础骨架..."
        cat > "$config_file" <<EOF
{
  "meta": { "lastTouchedVersion": "2026.2.14" },
  "update": { "checkOnStart": false },
  "browser": {
    "headless": true,
    "noSandbox": true,
    "defaultProfile": "openclaw",
    "executablePath": "/usr/bin/chromium"
  },
  "models": { "mode": "merge", "providers": { "default": { "models": [] } } },
  "agents": {
    "defaults": {
      "compaction": { "mode": "safeguard" },
      "elevatedDefault": "full",
      "maxConcurrent": 4,
      "subagents": { "maxConcurrent": 8 }
    }
  },
  "messages": { "ackReactionScope": "group-mentions", "tts": { "edge": { "voice": "zh-CN-XiaoxiaoNeural" } } },
  "commands": { "native": "auto", "nativeSkills": "auto" },
  "channels": {},
  "plugins": { "entries": {}, "installs": {} },
    "memory": {
      "backend": "qmd",
      "qmd": {
        "command": "/usr/local/bin/qmd",
        "paths": [
          {
            "path": "/home/node/.openclaw/workspace",
            "name": "workspace",
            "pattern": "**/*.md"
          }
        ]
      }
    }
}
EOF
    fi

    echo "正在根据当前环境变量同步配置状态..."
    python3 -c "
import json, sys, os
from datetime import datetime

def sync():
    path = '$config_file'
    try:
        with open(path, 'r', encoding='utf-8') as f:
            config = json.load(f)
        
        env = os.environ
        
        def ensure_path(cfg, keys):
            curr = cfg
            for k in keys:
                if k not in curr: curr[k] = {}
                curr = curr[k]
            return curr

        # --- 0. 飞书旧版本格式迁移 ---
        feishu_raw = config.get('channels', {}).get('feishu', {})
        if 'appId' in feishu_raw and 'accounts' not in feishu_raw:
            print('检测到飞书旧版本格式，执行迁移...')
            old_app_id = feishu_raw.pop('appId', '')
            old_app_secret = feishu_raw.pop('appSecret', '')
            old_bot_name = feishu_raw.pop('botName', 'OpenClaw Bot')
            feishu_raw['accounts'] = {'main': {'appId': old_app_id, 'appSecret': old_app_secret, 'botName': old_bot_name}}

        # --- 1. 模型同步 ---
        if env.get('API_KEY') and env.get('BASE_URL'):
            p = ensure_path(config, ['models', 'providers', 'default'])
            p['baseUrl'] = env['BASE_URL']
            p['apiKey'] = env['API_KEY']
            p['api'] = env.get('API_PROTOCOL') or 'openai-completions'
            
            mid = env.get('MODEL_ID') or 'gpt-4o'
            mlist = p.get('models', [])
            m_obj = next((m for m in mlist if m.get('id') == mid), None)
            if not m_obj:
                m_obj = {'id': mid, 'name': mid, 'reasoning': False, 'input': ['text', 'image'], 
                         'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0}}
                mlist.append(m_obj)
            
            m_obj['contextWindow'] = int(env.get('CONTEXT_WINDOW') or 200000)
            m_obj['maxTokens'] = int(env.get('MAX_TOKENS') or 8192)
            p['models'] = mlist
            
            # 同步更新默认模型
            ensure_path(config, ['agents', 'defaults', 'model'])['primary'] = f'default/{mid}'
            ensure_path(config, ['agents', 'defaults', 'imageModel'])['primary'] = f'default/{mid}'
            
            # 工作区同步：存在则更新，不存在则恢复默认
            config['agents']['defaults']['workspace'] = env.get('WORKSPACE') or '/home/node/.openclaw/workspace'
            
            # 同步更新 memory 路径
            if 'memory' in config and 'qmd' in config['memory']:
                config['memory']['qmd']['command'] = '/usr/local/bin/qmd'
                for p in config['memory']['qmd'].get('paths', []):
                    if p.get('name') == 'workspace':
                        p['path'] = config['agents']['defaults']['workspace']
            
            print(f'✅ 模型与工作区同步: {mid}')

        # --- 2. 渠道与插件同步 (声明式) ---
        channels = ensure_path(config, ['channels'])
        entries = ensure_path(config, ['plugins', 'entries'])
        installs = ensure_path(config, ['plugins', 'installs'])

        def sync_feishu(c, e):
            c.update({'enabled': True, 'dmPolicy': 'pairing', 'groupPolicy': 'open'})
            main = ensure_path(c, ['accounts', 'main'])
            main.update({
                'appId': e['FEISHU_APP_ID'], 
                'appSecret': e['FEISHU_APP_SECRET'],
                'botName': e.get('FEISHU_BOT_NAME') or 'OpenClaw Bot'
            })
            if e.get('FEISHU_DOMAIN'): main['domain'] = e['FEISHU_DOMAIN']

        def sync_dingtalk(c, e):
            c.update({
                'enabled': True, 'clientId': e['DINGTALK_CLIENT_ID'], 
                'clientSecret': e['DINGTALK_CLIENT_SECRET'],
                'robotCode': e.get('DINGTALK_ROBOT_CODE') or e['DINGTALK_CLIENT_ID'],
                'dmPolicy': 'open', 'groupPolicy': 'open', 'messageType': 'markdown'
            })
            if e.get('DINGTALK_CORP_ID'): c['corpId'] = e['DINGTALK_CORP_ID']
            if e.get('DINGTALK_AGENT_ID'): c['agentId'] = e['DINGTALK_AGENT_ID']

        def sync_wecom(c, e):
            c.update({'enabled': True, 'token': e['WECOM_TOKEN'], 'encodingAesKey': e['WECOM_ENCODING_AES_KEY']})
            if 'commands' not in c:
                c['commands'] = {'enabled': True, 'allowlist': ['/new', '/status', '/help', '/compact']}

        def sync_wecom_app(c, e):
            c.update({
                'enabled': True,
                'corpId': e['WECOM_APP_CORP_ID'],
                'corpSecret': e['WECOM_APP_CORP_SECRET'],
                'agentId': e['WECOM_APP_AGENT_ID'],
                'callbackToken': e['WECOM_APP_CALLBACK_TOKEN'],
                'callbackAesKey': e['WECOM_APP_CALLBACK_AES_KEY'],
            })
            if e.get('WECOM_APP_WEBHOOK_PATH'):
                c['webhookPath'] = e['WECOM_APP_WEBHOOK_PATH']
            if e.get('WECOM_APP_PROXY'):
                c['proxy'] = e['WECOM_APP_PROXY']
            if 'commands' not in c:
                c['commands'] = {'enabled': True, 'allowlist': ['/new', '/status', '/help', '/compact', '/clear']}

        # 同步规则矩阵
        sync_rules = [
            (['TELEGRAM_BOT_TOKEN'], 'telegram', 
             lambda c, e: c.update({'botToken': e['TELEGRAM_BOT_TOKEN'], 'dmPolicy': 'pairing', 'groupPolicy': 'allowlist', 'streamMode': 'partial'}),
             None),
            (['FEISHU_APP_ID', 'FEISHU_APP_SECRET'], 'feishu', sync_feishu,
             {'source': 'npm', 'spec': '@openclaw/feishu', 'installPath': '/home/node/.openclaw/extensions/feishu'}),
            (['DINGTALK_CLIENT_ID', 'DINGTALK_CLIENT_SECRET'], 'dingtalk', sync_dingtalk,
             {'source': 'npm', 'spec': 'https://github.com/soimy/clawdbot-channel-dingtalk.git', 'installPath': '/home/node/.openclaw/extensions/dingtalk'}),
            (['QQBOT_APP_ID', 'QQBOT_CLIENT_SECRET'], 'qqbot',
             lambda c, e: c.update({'enabled': True, 'appId': e['QQBOT_APP_ID'], 'clientSecret': e['QQBOT_CLIENT_SECRET']}),
             {'source': 'path', 'sourcePath': '/home/node/.openclaw/qqbot', 'installPath': '/home/node/.openclaw/extensions/qqbot'}),
            (['WECOM_TOKEN', 'WECOM_ENCODING_AES_KEY'], 'wecom', sync_wecom,
             {'source': 'npm', 'spec': '@sunnoy/wecom', 'installPath': '/home/node/.openclaw/extensions/wecom'}),
            (['WECOM_APP_CORP_ID', 'WECOM_APP_CORP_SECRET', 'WECOM_APP_AGENT_ID', 'WECOM_APP_CALLBACK_TOKEN', 'WECOM_APP_CALLBACK_AES_KEY'], 'wecom-app', sync_wecom_app,
             {'source': 'path', 'sourcePath': '/home/node/.openclaw/extensions/openclaw-wechat', 'installPath': '/home/node/.openclaw/extensions/openclaw-wechat'})
        ]

        for req_envs, cid, config_fn, install_info in sync_rules:
            has_env = all(env.get(k) for k in req_envs)
            if has_env:
                conf_obj = ensure_path(channels, [cid])
                config_fn(conf_obj, env)
                entries[cid] = {'enabled': True}
                if install_info and cid not in installs:
                    install_info['installedAt'] = datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'
                    installs[cid] = install_info
                print(f'✅ 渠道同步: {cid}')
            else:
                if cid in entries and entries[cid].get('enabled'):
                    entries[cid]['enabled'] = False
                    print(f'🚫 环境变量缺失，已禁用渠道: {cid}')

        # 特殊处理: openclaw-wechat 插件 ID 为 clawdbot-wecom，channel ID 为 wecom-app
        if entries.get('wecom-app', {}).get('enabled'):
            entries['clawdbot-wecom'] = {'enabled': True}
            del entries['wecom-app']  # plugin ID is clawdbot-wecom, not wecom-app
            load = ensure_path(config, ['plugins', 'load'])
            paths = load.get('paths', [])
            wecom_path = '/home/node/.openclaw/extensions/openclaw-wechat'
            if wecom_path not in paths:
                paths.append(wecom_path)
            load['paths'] = paths

        # --- 3. Gateway 同步 ---
        if env.get('OPENCLAW_GATEWAY_TOKEN'):
            gw = ensure_path(config, ['gateway'])
            gw['port'] = int(env.get('OPENCLAW_GATEWAY_PORT') or 18789)
            gw['bind'] = env.get('OPENCLAW_GATEWAY_BIND') or '0.0.0.0'
            gw['mode'] = 'local'
            ensure_path(gw, ['auth'])['token'] = env['OPENCLAW_GATEWAY_TOKEN']
            print('✅ Gateway 同步完成')

        # 保存并更新时间戳
        ensure_path(config, ['meta'])['lastTouchedAt'] = datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'
        with open(path, 'w', encoding='utf-8') as f:
            json.dump(config, f, indent=2, ensure_ascii=False)
            
    except Exception as e:
        print(f'❌ 同步失败: {e}', file=sys.stderr)
        sys.exit(1)

sync()
"
}

sync_config_with_env

# 确保所有文件和目录的权限正确（仅 root 可执行）
if [ "$(id -u)" -eq 0 ]; then
    chown -R node:node "$OPENCLAW_HOME" || true
fi

echo "=== 初始化完成 ==="
echo "当前使用模型: default/$MODEL_ID"
echo "API 协议: ${API_PROTOCOL:-openai-completions}"
echo "Base URL: ${BASE_URL}"
echo "上下文窗口: ${CONTEXT_WINDOW:-200000}"
echo "最大 Tokens: ${MAX_TOKENS:-8192}"
echo "Gateway 端口: $OPENCLAW_GATEWAY_PORT"
echo "Gateway 绑定: $OPENCLAW_GATEWAY_BIND"

# 安装 bun
export BUN_INSTALL="/usr/local"
export PATH="$BUN_INSTALL/bin:$PATH"

# 启动 OpenClaw Gateway（切换到 node 用户）
echo "=== 启动 OpenClaw Gateway ==="

export DBUS_SESSION_BUS_ADDRESS=/dev/null

# 定义清理函数
cleanup() {
    echo "=== 接收到停止信号,正在关闭服务 ==="
    if [ -n "$GATEWAY_PID" ]; then
        kill -TERM "$GATEWAY_PID" 2>/dev/null || true
        wait "$GATEWAY_PID" 2>/dev/null || true
    fi
    echo "=== 服务已停止 ==="
    exit 0
}

# 捕获终止信号
trap cleanup SIGTERM SIGINT SIGQUIT

# 启动网关
gosu node env HOME=/home/node DBUS_SESSION_BUS_ADDRESS=/dev/null \
    BUN_INSTALL="/usr/local" PATH="/usr/local/bin:$PATH" \
    openclaw gateway run \
    --bind "$OPENCLAW_GATEWAY_BIND" \
    --port "$OPENCLAW_GATEWAY_PORT" \
    --token "$OPENCLAW_GATEWAY_TOKEN" \
    --verbose &
GATEWAY_PID=$!

echo "=== OpenClaw Gateway 已启动 (PID: $GATEWAY_PID) ==="

# 主进程等待子进程
wait "$GATEWAY_PID"
EXIT_CODE=$?

echo "=== OpenClaw Gateway 已退出 (退出码: $EXIT_CODE) ==="
exit $EXIT_CODE
