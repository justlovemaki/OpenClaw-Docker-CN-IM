#!/bin/bash

set -e

OPENCLAW_HOME="/home/node/.openclaw"
OPENCLAW_WORKSPACE="${WORKSPACE:-/home/node/.openclaw/workspace}"
NODE_UID="$(id -u node)"
NODE_GID="$(id -g node)"
GATEWAY_PID=""

log_section() {
    echo "=== $1 ==="
}

ensure_directories() {
    mkdir -p "$OPENCLAW_HOME" "$OPENCLAW_WORKSPACE"
}

is_root() {
    [ "$(id -u)" -eq 0 ]
}

fix_permissions_if_needed() {
    if ! is_root; then
        return
    fi

    local current_owner
    current_owner="$(stat -c '%u:%g' "$OPENCLAW_HOME" 2>/dev/null || echo unknown:unknown)"

    echo "挂载目录: $OPENCLAW_HOME"
    echo "当前所有者(UID:GID): $current_owner"
    echo "目标所有者(UID:GID): ${NODE_UID}:${NODE_GID}"

    if [ "$current_owner" != "${NODE_UID}:${NODE_GID}" ]; then
        echo "检测到宿主机挂载目录所有者与容器运行用户不一致，尝试自动修复..."
        chown -R node:node "$OPENCLAW_HOME" || true
    fi

    if ! gosu node test -w "$OPENCLAW_HOME"; then
        echo "❌ 权限检查失败：node 用户无法写入 $OPENCLAW_HOME"
        echo "请在宿主机执行（Linux）："
        echo "  sudo chown -R ${NODE_UID}:${NODE_GID} <your-openclaw-data-dir>"
        echo "或在启动时显式指定用户："
        echo "  docker run --user \$(id -u):\$(id -g) ..."
        echo "若宿主机启用了 SELinux，请在挂载卷后添加 :z 或 :Z"
        exit 1
    fi
}

ensure_base_config() {
    local config_file="$OPENCLAW_HOME/openclaw.json"

    if [ -f "$config_file" ]; then
        return
    fi

    echo "配置文件不存在，创建基础骨架..."
    cat > "$config_file" <<'EOF'
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
      "sandbox": { "mode": "off" },
      "elevatedDefault": "full",
      "maxConcurrent": 4,
      "subagents": { "maxConcurrent": 8 }
    }
  },
  "messages": { "ackReactionScope": "group-mentions", "tts": { "edge": { "voice": "zh-CN-XiaoxiaoNeural" } } },
  "commands": { "native": "auto", "nativeSkills": "auto" },
  "tools": {
    "profile": "full",
    "sessions": {
      "visibility": "all"
    },
    "fs": {
      "workspaceOnly": true
    }
  },
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
}

sync_config_with_env() {
    local config_file="$OPENCLAW_HOME/openclaw.json"

    ensure_base_config

    echo "正在根据当前环境变量同步配置状态..."
    CONFIG_FILE="$config_file" python3 - <<'PYCODE'
import json
import os
import re
import sys
from copy import deepcopy
from datetime import datetime

WECOM_ACCOUNT_ID_RE = re.compile(r'^[a-z0-9_-]+$')
WECOM_ACCOUNT_FIELDS = {
    'botId', 'secret', 'dmPolicy', 'allowFrom', 'groupPolicy', 'groupAllowFrom',
    'welcomeMessage', 'sendThinkingMessage', 'agent', 'webhooks', 'network',
    'groupChat', 'dm', 'workspaceTemplate'
}
WECOM_RESERVED_FIELDS = {'enabled', 'defaultAccount', 'adminUsers', 'commands', 'dynamicAgents'}
QQBOT_ACCOUNT_FIELDS = {'appId', 'clientSecret', 'enabled'}
QQBOT_RESERVED_FIELDS = {'enabled', 'appId', 'clientSecret', 'dmPolicy', 'allowFrom', 'groupPolicy', 'accounts'}

CHANNEL_INSTALLS = {
    'feishu': {'source': 'npm', 'spec': '@openclaw/feishu', 'installPath': '/home/node/.openclaw/extensions/feishu'},
    'dingtalk': {'source': 'npm', 'spec': 'https://github.com/soimy/clawdbot-channel-dingtalk.git', 'installPath': '/home/node/.openclaw/extensions/dingtalk'},
    'qqbot': {'source': 'path', 'sourcePath': '/home/node/.openclaw/qqbot', 'installPath': '/home/node/.openclaw/extensions/qqbot'},
    'napcat': {'source': 'path', 'sourcePath': '/home/node/.openclaw/extensions/napcat', 'installPath': '/home/node/.openclaw/extensions/napcat'},
    'wecom': {'source': 'npm', 'spec': '@sunnoy/wecom', 'installPath': '/home/node/.openclaw/extensions/wecom'},
}


def strip_json_comments_and_trailing_commas(raw):
    raw = re.sub(r'/\*.*?\*/', '', raw, flags=re.S)
    raw = re.sub(r'(^|\s)//.*?$', '', raw, flags=re.M)
    raw = re.sub(r'(^|\s)#.*?$', '', raw, flags=re.M)
    raw = re.sub(r',(?=\s*[}\]])', '', raw)
    return raw


def load_config_with_compat(path):
    with open(path, 'r', encoding='utf-8') as f:
        raw = f.read()

    try:
        return json.loads(raw)
    except json.JSONDecodeError as original_error:
        sanitized = strip_json_comments_and_trailing_commas(raw)
        try:
            config = json.loads(sanitized)
            print('⚠️ 检测到 openclaw.json 含注释或尾随逗号，已按兼容模式自动解析并在保存时标准化为合法 JSON')
            return config
        except json.JSONDecodeError:
            raise ValueError(f'openclaw.json 格式非法: {original_error}')


def ensure_path(cfg, keys):
    curr = cfg
    for key in keys:
        if key not in curr or not isinstance(curr.get(key), dict):
            curr[key] = {}
        curr = curr[key]
    return curr


def deep_merge(dst, src):
    if not isinstance(dst, dict) or not isinstance(src, dict):
        return src
    for key, value in src.items():
        if isinstance(value, dict) and isinstance(dst.get(key), dict):
            dst[key] = deep_merge(dst[key], value)
        else:
            dst[key] = value
    return dst


def parse_bool(value, default=False):
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in ('1', 'true', 'yes', 'on')


def parse_csv(value):
    if value is None:
        return []
    if isinstance(value, list):
        return value
    return [item.strip() for item in str(value).split(',') if item.strip()]


def parse_json_object(raw, env_name):
    raw = (raw or '').strip()
    if not raw:
        return None
    try:
        parsed = json.loads(raw)
    except Exception as ex:
        raise ValueError(f'{env_name} 不是合法 JSON: {ex}')
    if not isinstance(parsed, dict):
        raise ValueError(f'{env_name} 必须是 JSON 对象')
    return parsed


def utc_now_iso():
    return datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'


def first_csv_item(raw, default=''):
    values = parse_csv(raw)
    return values[0] if values else default


def normalize_model_ref(raw, provider_names=None, default_provider='default'):
    """归一化模型引用，确保包含 provider 前缀。

    规则：
    1. 不含 / 时，补成 default/<model_id>
    2. 含 / 且首段是已知 provider 名称时，视为完整 provider/model 引用，原样返回
    3. 含 / 但首段不是已知 provider 名称时，视为 default provider 下的模型 ID，补成 default/<raw>
    """
    val = str(raw or '').strip()
    if not val:
        return ''

    provider_names = set(provider_names or [])
    provider_names.add(default_provider)

    if '/' not in val:
        return f'{default_provider}/{val}'

    provider_prefix = val.split('/', 1)[0].strip()
    if provider_prefix in provider_names:
        return val

    return f'{default_provider}/{val}'


def resolve_primary_model(env, default_model_id, provider_names=None):
    """
    解析主模型：
    1. 优先使用 PRIMARY_MODEL。
    2. 留空时，使用默认模型。
    3. 归一化时仅当首段是已知 provider 名称时，才视为 provider/model；否则补 default/。
    """
    raw = str(env.get('PRIMARY_MODEL') or '').strip()
    if raw:
        return normalize_model_ref(raw, provider_names=provider_names)
    return normalize_model_ref(default_model_id, provider_names=provider_names)


def resolve_image_model(env, default_model_id, provider_names=None):
    """
    解析图片模型：
    1. 优先使用 IMAGE_MODEL_ID。
    2. 留空时，回退到默认模型。
    3. 归一化规则与主模型一致。
    """
    raw = str(env.get('IMAGE_MODEL_ID') or '').strip()
    if raw:
        return normalize_model_ref(raw, provider_names=provider_names)
    return normalize_model_ref(default_model_id, provider_names=provider_names)


def is_valid_account_id(account_id):
    return WECOM_ACCOUNT_ID_RE.match(str(account_id)) is not None


def is_wecom_account_config(value):
    return isinstance(value, dict) and any(key in value for key in WECOM_ACCOUNT_FIELDS)


def is_qqbot_account_config(value):
    return isinstance(value, dict) and any(key in value for key in QQBOT_ACCOUNT_FIELDS)


def get_wecom_accounts(wecom):
    if not isinstance(wecom, dict):
        return []
    accounts = []
    for account_id, cfg in wecom.items():
        if account_id in WECOM_RESERVED_FIELDS:
            continue
        if is_wecom_account_config(cfg):
            accounts.append((account_id, cfg))
    return accounts


def get_qqbot_accounts(qqbot):
    if not isinstance(qqbot, dict):
        return []
    accounts = qqbot.get('accounts')
    if not isinstance(accounts, dict):
        return []
    result = []
    for account_id, cfg in accounts.items():
        if is_valid_account_id(account_id) and is_qqbot_account_config(cfg):
            result.append((account_id, cfg))
    return result


def normalize_wecom_config(channels):
    wecom = channels.get('wecom')
    if not isinstance(wecom, dict):
        return

    normalized = {}
    migrated = False

    for key in WECOM_RESERVED_FIELDS:
        if key in wecom:
            normalized[key] = wecom[key]

    for key, value in wecom.items():
        if key in WECOM_RESERVED_FIELDS:
            continue
        if is_valid_account_id(key) and is_wecom_account_config(value):
            normalized[key] = value
            continue
        if key in WECOM_ACCOUNT_FIELDS:
            default_account_id = str(wecom.get('defaultAccount') or 'default').strip() or 'default'
            default_cfg = normalized.get(default_account_id)
            if not isinstance(default_cfg, dict):
                default_cfg = {}
            default_cfg.setdefault(key, value)
            normalized[default_account_id] = default_cfg
            migrated = True

    if normalized and normalized != wecom:
        channels['wecom'] = normalized
        migrated = True

    if migrated:
        print('✅ 企业微信配置已标准化为当前多账号结构')


def normalize_qqbot_config(channels):
    qqbot = channels.get('qqbot')
    if not isinstance(qqbot, dict):
        return

    migrated = False
    accounts = qqbot.get('accounts')
    if not isinstance(accounts, dict):
        accounts = {}

    legacy_account = {key: qqbot[key] for key in ('appId', 'clientSecret') if key in qqbot}
    if legacy_account:
        default_cfg = accounts.get('default', {})
        if not isinstance(default_cfg, dict):
            default_cfg = {}
        for key, value in legacy_account.items():
            default_cfg.setdefault(key, value)
        if 'enabled' not in default_cfg and isinstance(qqbot.get('enabled'), bool):
            default_cfg['enabled'] = qqbot['enabled']
        accounts['default'] = default_cfg
        migrated = True

    main_account = accounts.pop('main', None) if 'main' in accounts else None
    if isinstance(main_account, dict):
        default_cfg = accounts.get('default', {})
        if not isinstance(default_cfg, dict):
            default_cfg = {}
        for key, value in main_account.items():
            default_cfg.setdefault(key, value)
        accounts['default'] = default_cfg
        migrated = True

    normalized_accounts = {}
    for account_id, cfg in accounts.items():
        if is_valid_account_id(account_id) and is_qqbot_account_config(cfg):
            normalized_accounts[account_id] = cfg

    if normalized_accounts:
        qqbot['accounts'] = normalized_accounts
        default_cfg = normalized_accounts.get('default')
        if isinstance(default_cfg, dict):
            if default_cfg.get('appId'):
                qqbot['appId'] = default_cfg['appId']
            if default_cfg.get('clientSecret'):
                qqbot['clientSecret'] = default_cfg['clientSecret']
        migrated = migrated or qqbot.get('accounts') != accounts

    if migrated:
        print('✅ QQ 机器人配置已标准化为多 Bot 结构（旧单账号已兼容为 default）')


def migrate_feishu_config(channels_root):
    feishu = channels_root.get('feishu', {})
    if 'appId' in feishu and 'accounts' not in feishu:
        print('检测到飞书旧版格式，执行迁移...')
        feishu['accounts'] = {
            'default': {
                'appId': feishu.get('appId', ''),
                'appSecret': feishu.get('appSecret', ''),
                'botName': feishu.get('botName', 'OpenClaw Bot'),
            }
        }

    accounts = feishu.get('accounts')
    if isinstance(accounts, dict) and 'main' in accounts:
        print('检测到飞书 accounts.main，迁移为 accounts.default...')
        main_account = accounts.pop('main')
        default_account = accounts.get('default')
        if not isinstance(default_account, dict):
            accounts['default'] = main_account if isinstance(main_account, dict) else {}
        elif isinstance(main_account, dict):
            for key, value in main_account.items():
                default_account.setdefault(key, value)

    default_account = accounts.get('default') if isinstance(accounts, dict) else None
    if isinstance(default_account, dict):
        if default_account.get('appId'):
            feishu['appId'] = default_account['appId']
        if default_account.get('appSecret'):
            feishu['appSecret'] = default_account['appSecret']


def merge_wecom_accounts_from_env(channels, env):
    raw = (env.get('WECOM_ACCOUNTS_JSON') or '').strip()
    if not raw:
        return False

    try:
        parsed = json.loads(raw)
    except Exception as ex:
        raise ValueError(f'WECOM_ACCOUNTS_JSON 不是合法 JSON: {ex}')

    if not isinstance(parsed, dict):
        raise ValueError('WECOM_ACCOUNTS_JSON 必须是对象，格式为 {"open": {...}, "support": {...}}')

    if 'accounts' in parsed and isinstance(parsed.get('accounts'), dict):
        parsed = parsed['accounts']
    elif 'wecom' in parsed and isinstance(parsed.get('wecom'), dict):
        parsed = {
            key: value
            for key, value in parsed['wecom'].items()
            if key not in WECOM_RESERVED_FIELDS and is_valid_account_id(key)
        }

    wecom = channels.get('wecom')
    if not isinstance(wecom, dict):
        wecom = {}
        channels['wecom'] = wecom

    changed = False
    for account_id, account_cfg in parsed.items():
        if not is_valid_account_id(account_id):
            raise ValueError(f'WECOM_ACCOUNTS_JSON 账号 ID 不合法: {account_id}，仅支持小写字母、数字、-、_')
        if not isinstance(account_cfg, dict) or not is_wecom_account_config(account_cfg):
            raise ValueError(f'WECOM_ACCOUNTS_JSON 账号配置非法: {account_id}，至少包含 botId/secret/agent/webhooks/dmPolicy 中的一项')

        old_cfg = wecom.get(account_id)
        if not isinstance(old_cfg, dict):
            old_cfg = {}
        wecom[account_id] = deep_merge(old_cfg, account_cfg)
        changed = True

    if changed:
        wecom['enabled'] = True
        print('✅ 已从企业微信多账号环境变量同步配置')
    return changed


def merge_qqbot_bots_from_env(channels, env):
    raw = (env.get('QQBOT_BOTS_JSON') or '').strip()
    if not raw:
        return False

    try:
        parsed = json.loads(raw)
    except Exception as ex:
        raise ValueError(f'QQBOT_BOTS_JSON 不是合法 JSON: {ex}')

    if not isinstance(parsed, dict):
        raise ValueError('QQBOT_BOTS_JSON 必须是对象，格式为 {"bot1": {...}, "bot2": {...}}')

    if 'accounts' in parsed and isinstance(parsed.get('accounts'), dict):
        parsed = parsed['accounts']
    elif 'qqbot' in parsed and isinstance(parsed.get('qqbot'), dict):
        qqbot_payload = parsed['qqbot']
        if 'accounts' in qqbot_payload and isinstance(qqbot_payload.get('accounts'), dict):
            parsed = qqbot_payload['accounts']
        else:
            parsed = {key: value for key, value in qqbot_payload.items() if key not in QQBOT_RESERVED_FIELDS}

    qqbot = channels.get('qqbot')
    if not isinstance(qqbot, dict):
        qqbot = {}
        channels['qqbot'] = qqbot

    accounts = qqbot.get('accounts')
    if not isinstance(accounts, dict):
        accounts = {}
        qqbot['accounts'] = accounts

    changed = False
    for account_id, account_cfg in parsed.items():
        if not is_valid_account_id(account_id):
            raise ValueError(f'QQBOT_BOTS_JSON 账号 ID 不合法: {account_id}，仅支持小写字母、数字、-、_')
        if not isinstance(account_cfg, dict) or not is_qqbot_account_config(account_cfg):
            raise ValueError(f'QQBOT_BOTS_JSON 账号配置非法: {account_id}，至少包含 appId/clientSecret/enabled 中的一项')

        old_cfg = accounts.get(account_id)
        if not isinstance(old_cfg, dict):
            old_cfg = {}
        accounts[account_id] = deep_merge(old_cfg, account_cfg)
        changed = True

    if changed:
        qqbot['enabled'] = True
        default_cfg = accounts.get('default')
        if isinstance(default_cfg, dict):
            if default_cfg.get('appId'):
                qqbot['appId'] = default_cfg['appId']
            if default_cfg.get('clientSecret'):
                qqbot['clientSecret'] = default_cfg['clientSecret']
        print('✅ 已从 QQ 机器人多 Bot 环境变量同步配置')
    return changed


def validate_wecom_multi_accounts(channels):
    wecom = channels.get('wecom')
    if not isinstance(wecom, dict):
        return

    accounts = get_wecom_accounts(wecom)
    if not accounts:
        return

    account_map = dict(accounts)
    default_account = (wecom.get('defaultAccount') or '').strip() if isinstance(wecom.get('defaultAccount'), str) else ''
    if default_account and default_account not in account_map:
        raise ValueError(f'企业微信 defaultAccount 不存在: {default_account}')

    bot_id_index = {}
    agent_id_index = {}
    for account_id, cfg in accounts:
        if not is_valid_account_id(account_id):
            raise ValueError(f'企业微信账号 ID 不合法: {account_id}，仅支持小写字母、数字、-、_')

        bot_id = str(cfg.get('botId') or '').strip()
        if bot_id:
            bot_id_index.setdefault(bot_id, []).append(account_id)

        agent = cfg.get('agent') if isinstance(cfg.get('agent'), dict) else None
        if agent:
            agent_id = agent.get('agentId')
            if agent_id is not None and str(agent_id).strip() != '':
                agent_id_index.setdefault(str(agent_id).strip(), []).append(account_id)

    duplicate_bot_ids = {key: value for key, value in bot_id_index.items() if len(value) > 1}
    if duplicate_bot_ids:
        detail = '; '.join([f"{bot_id}: {', '.join(ids)}" for bot_id, ids in duplicate_bot_ids.items()])
        raise ValueError(f'企业微信 botId 冲突（可能导致消息路由错乱）: {detail}')

    duplicate_agent_ids = {key: value for key, value in agent_id_index.items() if len(value) > 1}
    if duplicate_agent_ids:
        detail = '; '.join([f"{agent_id}: {', '.join(ids)}" for agent_id, ids in duplicate_agent_ids.items()])
        raise ValueError(f'企业微信 Agent ID 冲突（可能导致消息路由错乱）: {detail}')


def validate_qqbot_multi_accounts(channels):
    qqbot = channels.get('qqbot')
    if not isinstance(qqbot, dict):
        return

    accounts = get_qqbot_accounts(qqbot)
    if not accounts:
        return

    app_id_index = {}
    for account_id, cfg in accounts:
        if not is_valid_account_id(account_id):
            raise ValueError(f'QQ 机器人账号 ID 不合法: {account_id}，仅支持小写字母、数字、-、_')
        app_id = str(cfg.get('appId') or '').strip()
        if app_id:
            app_id_index.setdefault(app_id, []).append(account_id)

    duplicate_app_ids = {key: value for key, value in app_id_index.items() if len(value) > 1}
    if duplicate_app_ids:
        detail = '; '.join([f"{app_id}: {', '.join(ids)}" for app_id, ids in duplicate_app_ids.items()])
        raise ValueError(f'QQ 机器人 AppID 冲突（可能导致消息路由错乱）: {detail}')


class SyncContext:
    def __init__(self, config, env):
        self.config = config
        self.env = env
        self.channels = ensure_path(config, ['channels'])
        self.plugins = ensure_path(config, ['plugins'])
        self.entries = ensure_path(self.plugins, ['entries'])
        self.installs = ensure_path(self.plugins, ['installs'])
        self.default_dm_policy = env.get('DM_POLICY') or 'open'
        self.default_allow_from = parse_csv(env.get('ALLOW_FROM')) or ['*']
        self.default_group_policy = env.get('GROUP_POLICY') or 'open'
        self.multi_account_channels = {'wecom', 'qqbot'}
        self.has_wecom_single_env = bool((env.get('WECOM_BOT_ID') or '').strip() and (env.get('WECOM_SECRET') or '').strip())
        self.has_wecom_accounts_env = bool((env.get('WECOM_ACCOUNTS_JSON') or '').strip())
        self.has_wecom_any_env = self.has_wecom_single_env or self.has_wecom_accounts_env
        self.has_qqbot_single_env = bool((env.get('QQBOT_APP_ID') or '').strip() and (env.get('QQBOT_CLIENT_SECRET') or '').strip())
        self.has_qqbot_bots_env = bool((env.get('QQBOT_BOTS_JSON') or '').strip())
        self.has_qqbot_any_env = self.has_qqbot_single_env or self.has_qqbot_bots_env
        self.feishu_plugin_env = (env.get('FEISHU_OFFICIAL_PLUGIN_ENABLED') or '').strip().lower()
        self.feishu_plugin_enabled = self.feishu_plugin_env in ('1', 'true', 'yes', 'on')
        self.feishu_plugin_explicit = self.feishu_plugin_env in ('0', '1', 'false', 'true', 'no', 'yes', 'off', 'on')

    def channel(self, channel_id):
        return ensure_path(self.channels, [channel_id])

    def entry(self, channel_id):
        return ensure_path(self.entries, [channel_id])

    def install(self, channel_id):
        install_info = CHANNEL_INSTALLS.get(channel_id)
        if install_info and channel_id not in self.installs:
            payload = deepcopy(install_info)
            payload['installedAt'] = utc_now_iso()
            self.installs[channel_id] = payload

    def enable_channel(self, channel_id, install=False):
        self.entries[channel_id] = {'enabled': True}
        if install:
            self.install(channel_id)

    def disable_channel(self, channel_id):
        self.entries[channel_id] = {'enabled': False}

    def is_channel_explicitly_disabled(self, channel_id):
        entry = self.entries.get(channel_id)
        return isinstance(entry, dict) and (entry.get('enabled') is False)


def sync_models(ctx):
    sync_model = (ctx.env.get('SYNC_MODEL_CONFIG') or 'true').strip().lower()
    if sync_model not in ('', 'true', '1', 'yes'):
        return

    def sync_provider(provider_name, api_key, base_url, protocol, model_ids_raw, context_window, max_tokens):
        if not ((api_key and base_url) or model_ids_raw):
            return None

        provider = ensure_path(ctx.config, ['models', 'providers', provider_name])
        if api_key:
            provider['apiKey'] = api_key
        if base_url:
            provider['baseUrl'] = base_url
        provider['api'] = protocol or 'openai-completions'

        models = provider.get('models', [])
        model_ids = parse_csv(model_ids_raw)
        for model_id in model_ids:
            model_obj = next((item for item in models if item.get('id') == model_id), None)
            if not model_obj:
                model_obj = {
                    'id': model_id,
                    'name': model_id,
                    'reasoning': False,
                    'input': ['text', 'image'],
                    'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0},
                }
                models.append(model_obj)
            model_obj['contextWindow'] = int(context_window or 200000)
            model_obj['maxTokens'] = int(max_tokens or 8192)

        provider['models'] = models
        return provider_name

    primary_provider = sync_provider(
        'default',
        ctx.env.get('API_KEY'),
        ctx.env.get('BASE_URL'),
        ctx.env.get('API_PROTOCOL'),
        ctx.env.get('MODEL_ID') or 'gpt-4o',
        ctx.env.get('CONTEXT_WINDOW'),
        ctx.env.get('MAX_TOKENS'),
    )

    fallback_provider_name = ctx.env.get('MODEL2_NAME') or 'model2'
    fallback_provider = sync_provider(
        fallback_provider_name,
        ctx.env.get('MODEL2_API_KEY'),
        ctx.env.get('MODEL2_BASE_URL'),
        ctx.env.get('MODEL2_PROTOCOL'),
        ctx.env.get('MODEL2_MODEL_ID') or '',
        ctx.env.get('MODEL2_CONTEXT_WINDOW'),
        ctx.env.get('MODEL2_MAX_TOKENS'),
    )

    # 提取默认模型 ID (MODEL_ID 的第一个)
    default_model_id = first_csv_item(ctx.env.get('MODEL_ID') or 'gpt-4o', 'gpt-4o')
    primary_model_raw = str(ctx.env.get('PRIMARY_MODEL') or '').strip()
    image_model_raw = str(ctx.env.get('IMAGE_MODEL_ID') or '').strip()
    provider_names = set(ensure_path(ctx.config, ['models', 'providers']).keys())

    # 解析最终的主模型与图片模型引用
    primary_model = resolve_primary_model(ctx.env, default_model_id, provider_names=provider_names)
    primary_image_model = resolve_image_model(ctx.env, default_model_id, provider_names=provider_names)

    ensure_path(ctx.config, ['agents', 'defaults', 'model'])['primary'] = primary_model
    ensure_path(ctx.config, ['agents', 'defaults', 'imageModel'])['primary'] = primary_image_model

    workspace = ctx.env.get('WORKSPACE') or '/home/node/.openclaw/workspace'
    ctx.config['agents']['defaults']['workspace'] = workspace

    memory_cfg = ctx.config.get('memory', {}).get('qmd')
    if isinstance(memory_cfg, dict):
        memory_cfg['command'] = '/usr/local/bin/qmd'
        for path_item in memory_cfg.get('paths', []):
            if path_item.get('name') == 'workspace':
                path_item['path'] = workspace

    msg = f'✅ 模型同步完成: 主模型={primary_model}'
    if primary_model_raw:
        msg += f' (来自 PRIMARY_MODEL={primary_model_raw})'
    msg += f', 图片模型={primary_image_model}'
    if fallback_provider:
        msg += f', 已启用备用提供商: {fallback_provider_name}'
    print(msg)


def sync_agent_and_tools(ctx):
    ensure_path(ctx.config, ['agents', 'defaults', 'sandbox'])['mode'] = 'off'
    tools = ensure_path(ctx.config, ['tools'])
    tools['profile'] = 'full'
    ensure_path(tools, ['sessions'])['visibility'] = 'all'
    ensure_path(tools, ['fs'])['workspaceOnly'] = True
    print('✅ Agent/工具配置同步完成: sandbox.mode=off, profile=full, sessions.visibility=all, fs.workspaceOnly=true')


def sync_feishu_channel(ctx, channel):
    env = ctx.env
    channel.update({
        'enabled': True,
        'appId': env['FEISHU_APP_ID'],
        'appSecret': env['FEISHU_APP_SECRET'],
        'dmPolicy': env.get('FEISHU_DM_POLICY') or ctx.default_dm_policy,
        'allowFrom': parse_csv(env.get('FEISHU_ALLOW_FROM')) or ctx.default_allow_from,
        'groupPolicy': env.get('FEISHU_GROUP_POLICY') or ctx.default_group_policy,
        'streaming': parse_bool(env.get('FEISHU_STREAMING', 'true'), True),
        'footer': {
            'elapsed': parse_bool(env.get('FEISHU_FOOTER_ELAPSED', 'true'), True),
            'status': parse_bool(env.get('FEISHU_FOOTER_STATUS', 'true'), True),
        },
        'requireMention': parse_bool(env.get('FEISHU_REQUIRE_MENTION', 'true'), True),
    })

    default_account = ensure_path(channel, ['accounts', 'default'])
    default_account.update({
        'appId': env['FEISHU_APP_ID'],
        'appSecret': env['FEISHU_APP_SECRET'],
        'botName': env.get('FEISHU_BOT_NAME') or 'OpenClaw Bot',
    })
    if env.get('FEISHU_DOMAIN'):
        default_account['domain'] = env['FEISHU_DOMAIN']


def sync_dingtalk_channel(ctx, channel):
    env = ctx.env
    channel.update({
        'enabled': True,
        'clientId': env['DINGTALK_CLIENT_ID'],
        'clientSecret': env['DINGTALK_CLIENT_SECRET'],
        'robotCode': env.get('DINGTALK_ROBOT_CODE') or env['DINGTALK_CLIENT_ID'],
        'dmPolicy': env.get('DINGTALK_DM_POLICY') or ctx.default_dm_policy,
        'groupPolicy': env.get('DINGTALK_GROUP_POLICY') or ctx.default_group_policy,
        'messageType': 'markdown',
        'allowFrom': parse_csv(env.get('DINGTALK_ALLOW_FROM')) or ctx.default_allow_from,
    })
    if env.get('DINGTALK_CORP_ID'):
        channel['corpId'] = env['DINGTALK_CORP_ID']
    if env.get('DINGTALK_AGENT_ID'):
        channel['agentId'] = env['DINGTALK_AGENT_ID']


def sync_qqbot_channel(ctx, channel):
    env = ctx.env
    channel.update({
        'enabled': True,
        'appId': env['QQBOT_APP_ID'],
        'clientSecret': env['QQBOT_CLIENT_SECRET'],
        'dmPolicy': env.get('QQBOT_DM_POLICY') or ctx.default_dm_policy,
        'allowFrom': parse_csv(env.get('QQBOT_ALLOW_FROM')) or ctx.default_allow_from,
        'groupPolicy': env.get('QQBOT_GROUP_POLICY') or ctx.default_group_policy,
    })
    ensure_path(channel, ['accounts', 'default']).update({
        'enabled': True,
        'appId': env['QQBOT_APP_ID'],
        'clientSecret': env['QQBOT_CLIENT_SECRET'],
    })


def sync_napcat_channel(ctx, channel):
    env = ctx.env
    channel.update({
        'enabled': True,
        'reverseWsPort': int(env['NAPCAT_REVERSE_WS_PORT']),
        'requireMention': True,
        'rateLimitMs': 1000,
        'dmPolicy': env.get('NAPCAT_DM_POLICY') or ctx.default_dm_policy,
        'allowFrom': parse_csv(env.get('NAPCAT_ALLOW_FROM')) or ctx.default_allow_from,
        'groupPolicy': env.get('NAPCAT_GROUP_POLICY') or ctx.default_group_policy,
    })
    if env.get('NAPCAT_HTTP_URL'):
        channel['httpUrl'] = env['NAPCAT_HTTP_URL']
    if env.get('NAPCAT_ACCESS_TOKEN'):
        channel['accessToken'] = env['NAPCAT_ACCESS_TOKEN']
    if env.get('NAPCAT_ADMINS'):
        channel['admins'] = [int(item) for item in parse_csv(env.get('NAPCAT_ADMINS'))]


def sync_wecom_channel(ctx, channel):
    env = ctx.env
    channel['enabled'] = True
    channel['dmPolicy'] = env.get('WECOM_DM_POLICY') or ctx.default_dm_policy
    channel['allowFrom'] = parse_csv(env.get('WECOM_ALLOW_FROM')) or ctx.default_allow_from
    channel['groupPolicy'] = env.get('WECOM_GROUP_POLICY') or ctx.default_group_policy

    if env.get('WECOM_ADMIN_USERS'):
        channel['adminUsers'] = parse_csv(env.get('WECOM_ADMIN_USERS'))

    commands = ensure_path(channel, ['commands'])
    commands['enabled'] = parse_bool(env.get('WECOM_COMMANDS_ENABLED'), True)
    commands['allowlist'] = parse_csv(env.get('WECOM_COMMANDS_ALLOWLIST')) or ['/new', '/compact', '/help', '/status']

    dynamic_agents = ensure_path(channel, ['dynamicAgents'])
    dynamic_agents['enabled'] = parse_bool(env.get('WECOM_DYNAMIC_AGENTS_ENABLED'), True)
    dynamic_agents['adminBypass'] = parse_bool(env.get('WECOM_DYNAMIC_AGENTS_ADMIN_BYPASS'), False)

    has_single_account = bool((env.get('WECOM_BOT_ID') or '').strip() and (env.get('WECOM_SECRET') or '').strip())
    if not has_single_account:
        return

    account_id = (env.get('WECOM_DEFAULT_ACCOUNT') or 'default').strip() or 'default'
    channel['defaultAccount'] = account_id
    account = ensure_path(channel, [account_id])
    account.update({'botId': env['WECOM_BOT_ID'], 'secret': env['WECOM_SECRET']})

    optional_fields = {
        'WECOM_WELCOME_MESSAGE': 'welcomeMessage',
        'WECOM_DM_POLICY': 'dmPolicy',
        'WECOM_GROUP_POLICY': 'groupPolicy',
        'WECOM_WORKSPACE_TEMPLATE': 'workspaceTemplate',
    }
    for env_name, field_name in optional_fields.items():
        if env.get(env_name):
            account[field_name] = env[env_name]

    if env.get('WECOM_ALLOW_FROM'):
        account['allowFrom'] = parse_csv(env.get('WECOM_ALLOW_FROM'))
    if env.get('WECOM_GROUP_ALLOW_FROM'):
        account['groupAllowFrom'] = parse_csv(env.get('WECOM_GROUP_ALLOW_FROM'))
    account['sendThinkingMessage'] = parse_bool(env.get('WECOM_SEND_THINKING_MESSAGE'), False)

    dm_cfg = ensure_path(account, ['dm'])
    dm_cfg['createAgentOnFirstMessage'] = parse_bool(env.get('WECOM_DM_CREATE_AGENT_ON_FIRST_MESSAGE'), True)

    group_chat = ensure_path(account, ['groupChat'])
    group_chat['enabled'] = parse_bool(env.get('WECOM_GROUP_CHAT_ENABLED'), True)
    group_chat['requireMention'] = parse_bool(env.get('WECOM_GROUP_CHAT_REQUIRE_MENTION'), True)
    group_chat['mentionPatterns'] = parse_csv(env.get('WECOM_GROUP_CHAT_MENTION_PATTERNS')) or ['@']

    if env.get('WECOM_AGENT_CORP_ID') or env.get('WECOM_AGENT_CORP_SECRET') or env.get('WECOM_AGENT_ID'):
        agent = ensure_path(account, ['agent'])
        if env.get('WECOM_AGENT_CORP_ID'):
            agent['corpId'] = env['WECOM_AGENT_CORP_ID']
        if env.get('WECOM_AGENT_CORP_SECRET'):
            agent['corpSecret'] = env['WECOM_AGENT_CORP_SECRET']
        if env.get('WECOM_AGENT_ID'):
            agent['agentId'] = int(env['WECOM_AGENT_ID'])

    webhook_map = parse_json_object(env.get('WECOM_WEBHOOKS_JSON'), 'WECOM_WEBHOOKS_JSON')
    if webhook_map is not None:
        account['webhooks'] = webhook_map

    network = {}
    if env.get('WECOM_NETWORK_EGRESS_PROXY_URL'):
        network['egressProxyUrl'] = env['WECOM_NETWORK_EGRESS_PROXY_URL']
    if env.get('WECOM_NETWORK_API_BASE_URL'):
        network['apiBaseUrl'] = env['WECOM_NETWORK_API_BASE_URL']
    if network:
        account['network'] = deep_merge(account.get('network', {}), network)


def apply_channel_rules(ctx):
    channel_labels = {
        'telegram': 'Telegram',
        'feishu': '飞书',
        'dingtalk': '钉钉',
        'qqbot': 'QQ 机器人',
        'napcat': 'NapCat',
        'wecom': '企业微信',
    }

    rules = [
        {
            'channel': 'telegram',
            'required_envs': ['TELEGRAM_BOT_TOKEN'],
            'sync': lambda channel: channel.update({
                'botToken': ctx.env['TELEGRAM_BOT_TOKEN'],
                'dmPolicy': ctx.env.get('TELEGRAM_DM_POLICY') or ctx.default_dm_policy,
                'allowFrom': parse_csv(ctx.env.get('TELEGRAM_ALLOW_FROM')) or ctx.default_allow_from,
                'groupPolicy': ctx.env.get('TELEGRAM_GROUP_POLICY') or ctx.default_group_policy,
                'streamMode': 'partial',
            }),
            'install': False,
        },
        {
            'channel': 'feishu',
            'required_envs': ['FEISHU_APP_ID', 'FEISHU_APP_SECRET'],
            'sync': lambda channel: sync_feishu_channel(ctx, channel),
            'install': True,
        },
        {
            'channel': 'dingtalk',
            'required_envs': ['DINGTALK_CLIENT_ID', 'DINGTALK_CLIENT_SECRET'],
            'sync': lambda channel: sync_dingtalk_channel(ctx, channel),
            'install': True,
        },
        {
            'channel': 'qqbot',
            'required_envs': ['QQBOT_APP_ID', 'QQBOT_CLIENT_SECRET'],
            'sync': lambda channel: sync_qqbot_channel(ctx, channel),
            'install': True,
        },
        {
            'channel': 'napcat',
            'required_envs': ['NAPCAT_REVERSE_WS_PORT'],
            'sync': lambda channel: sync_napcat_channel(ctx, channel),
            'install': True,
        },
        {
            'channel': 'wecom',
            'required_envs': ['WECOM_BOT_ID', 'WECOM_SECRET'],
            'sync': lambda channel: sync_wecom_channel(ctx, channel),
            'install': True,
        },
    ]

    for rule in rules:
        channel_id = rule['channel']
        channel_label = channel_labels.get(channel_id, channel_id)
        has_env = all(ctx.env.get(key) for key in rule['required_envs'])
        if has_env:
            channel = ctx.channel(channel_id)
            rule['sync'](channel)
            ctx.enable_channel(channel_id, install=rule['install'])
            print(f"✅ 渠道同步: {channel_label}")
            continue

        if channel_id == 'wecom' and not ctx.has_wecom_any_env:
            ctx.disable_channel(channel_id)
            continue

        if channel_id == 'qqbot' and not ctx.has_qqbot_any_env:
            ctx.disable_channel(channel_id)
            continue

        if ctx.entries.get(channel_id, {}).get('enabled'):
            ctx.disable_channel(channel_id)
            print(f"🚫 {channel_label} 环境变量缺失，已禁用渠道")
        else:
            print(f"ℹ️ {channel_label} 未提供环境变量，保持禁用")


def apply_wecom_legacy_v1_compat(ctx):
    has_new_single_account = bool((ctx.env.get('WECOM_BOT_ID') or '').strip() and (ctx.env.get('WECOM_SECRET') or '').strip())
    has_legacy_v1 = bool((ctx.env.get('WECOM_TOKEN') or '').strip() and (ctx.env.get('WECOM_ENCODING_AES_KEY') or '').strip())
    if has_new_single_account or not has_legacy_v1:
        return

    channel = ctx.channel('wecom')
    sync_wecom_channel(ctx, channel)
    ctx.enable_channel('wecom', install=True)
    print('✅ 渠道同步: 企业微信（兼容旧版环境变量）')


def apply_multi_account_plugin_state(ctx):
    wecom_accounts = get_wecom_accounts(ctx.channels.get('wecom'))
    if ctx.has_wecom_accounts_env:
        if wecom_accounts:
            ctx.enable_channel('wecom', install=True)
            print('✅ 已根据企业微信多账号环境变量启用插件')
        else:
            ctx.disable_channel('wecom')
            print('ℹ️ 企业微信多账号环境变量未生成有效账号，保持插件禁用')
    elif not ctx.has_wecom_any_env:
        ctx.disable_channel('wecom')
        print('ℹ️ 企业微信未提供任何环境变量，保持插件禁用')

    qqbot_accounts = get_qqbot_accounts(ctx.channels.get('qqbot'))
    if ctx.has_qqbot_bots_env:
        if qqbot_accounts:
            ctx.enable_channel('qqbot', install=True)
            print('✅ 已根据 QQ 机器人多 Bot 环境变量启用插件')
        else:
            ctx.disable_channel('qqbot')
            print('ℹ️ QQ 机器人多 Bot 环境变量未生成有效 Bot，保持插件禁用')
    elif not ctx.has_qqbot_any_env:
        ctx.disable_channel('qqbot')
        print('ℹ️ QQ 机器人未提供任何环境变量，保持插件禁用')


def apply_feishu_plugin_switch(ctx):
    has_credentials = bool(ctx.env.get('FEISHU_APP_ID') and ctx.env.get('FEISHU_APP_SECRET'))
    if ctx.feishu_plugin_explicit:
        ctx.entries['feishu-openclaw-plugin'] = {'enabled': ctx.feishu_plugin_enabled}
        ctx.entries['feishu'] = {'enabled': not ctx.feishu_plugin_enabled}
        if ctx.feishu_plugin_enabled:
            print('✅ 已启用插件开关: 飞书官方插件 feishu-openclaw-plugin')
            print('🚫 已自动禁用旧版渠道: 飞书')
        else:
            print('🚫 已禁用插件开关: 飞书官方插件 feishu-openclaw-plugin')
            print('✅ 已自动启用旧版渠道: 飞书')
        return

    ctx.entries['feishu-openclaw-plugin'] = {'enabled': False}
    ctx.entries['feishu'] = {'enabled': has_credentials}
    if has_credentials:
        print('ℹ️ 飞书官方插件开关未配置，默认启用旧版飞书渠道并禁用官方插件')
    else:
        print('ℹ️ 未检测到飞书凭证且飞书官方插件开关未配置，已同时禁用官方插件和旧版飞书渠道')


def finalize_plugins(ctx):
    ctx.plugins['allow'] = [name for name, entry in ctx.entries.items() if entry.get('enabled')]
    print('📦 已配置插件集合: ' + ', '.join(ctx.plugins['allow']))


def sync_channels_and_plugins(ctx):
    if ctx.env.get('OPENCLAW_PLUGINS_ENABLED'):
        ctx.plugins['enabled'] = ctx.env['OPENCLAW_PLUGINS_ENABLED'].lower() == 'true'

    apply_channel_rules(ctx)
    apply_wecom_legacy_v1_compat(ctx)
    merge_wecom_accounts_from_env(ctx.channels, ctx.env)
    merge_qqbot_bots_from_env(ctx.channels, ctx.env)
    apply_multi_account_plugin_state(ctx)
    apply_feishu_plugin_switch(ctx)
    finalize_plugins(ctx)
    validate_wecom_multi_accounts(ctx.channels)
    validate_qqbot_multi_accounts(ctx.channels)


def sync_gateway(ctx):
    if not ctx.env.get('OPENCLAW_GATEWAY_TOKEN'):
        return

    gateway = ensure_path(ctx.config, ['gateway'])
    gateway['port'] = int(ctx.env.get('OPENCLAW_GATEWAY_PORT') or 18789)
    gateway['bind'] = ctx.env.get('OPENCLAW_GATEWAY_BIND') or '0.0.0.0'
    gateway['mode'] = ctx.env.get('OPENCLAW_GATEWAY_MODE') or 'local'

    control_ui = ensure_path(gateway, ['controlUi'])
    control_ui['allowInsecureAuth'] = parse_bool(ctx.env.get('OPENCLAW_GATEWAY_ALLOW_INSECURE_AUTH', 'true'), True)
    control_ui['dangerouslyDisableDeviceAuth'] = parse_bool(ctx.env.get('OPENCLAW_GATEWAY_DANGEROUSLY_DISABLE_DEVICE_AUTH', 'false'), False)
    if ctx.env.get('OPENCLAW_GATEWAY_ALLOWED_ORIGINS'):
        control_ui['allowedOrigins'] = parse_csv(ctx.env.get('OPENCLAW_GATEWAY_ALLOWED_ORIGINS'))

    auth = ensure_path(gateway, ['auth'])
    auth['token'] = ctx.env['OPENCLAW_GATEWAY_TOKEN']
    auth['mode'] = ctx.env.get('OPENCLAW_GATEWAY_AUTH_MODE') or 'token'
    print('✅ Gateway 同步完成')


def sync():
    path = os.environ.get('CONFIG_FILE', '/home/node/.openclaw/openclaw.json')
    try:
        config = load_config_with_compat(path)
        ctx = SyncContext(config, os.environ)

        migrate_feishu_config(ctx.channels)
        normalize_wecom_config(ctx.channels)
        normalize_qqbot_config(ctx.channels)

        sync_models(ctx)
        sync_agent_and_tools(ctx)
        sync_channels_and_plugins(ctx)
        sync_gateway(ctx)

        ensure_path(ctx.config, ['meta'])['lastTouchedAt'] = utc_now_iso()
        with open(path, 'w', encoding='utf-8') as f:
            json.dump(ctx.config, f, indent=2, ensure_ascii=False)
    except Exception as exc:
        print(f'❌ 同步失败: {exc}', file=sys.stderr)
        sys.exit(1)


sync()
PYCODE
}

normalize_sync_check() {
    local sync_check="${SYNC_MODEL_CONFIG:-true}"
    sync_check="$(echo "$sync_check" | tr '[:upper:]' '[:lower:]' | xargs)"
    echo "$sync_check"
}

print_model_summary() {
    local sync_check final_mid final_imid
    sync_check="$(normalize_sync_check)"

    if [ "$sync_check" = "false" ] || [ "$sync_check" = "0" ] || [ "$sync_check" = "no" ]; then
        echo "模型配置: 手动模式 (跳过环境变量同步)"
        return
    fi

    final_mid="${PRIMARY_MODEL:-${MODEL_ID:-gpt-4o}}"
    if [[ "$final_mid" != */* ]]; then
        final_mid="default/$final_mid"
    else
        local provider_prefix="${final_mid%%/*}"
        if [[ "$provider_prefix" != "default" && "$provider_prefix" != "model2" ]]; then
            final_mid="default/$final_mid"
        fi
    fi

    final_imid="${IMAGE_MODEL_ID:-${MODEL_ID:-gpt-4o}}"
    if [[ "$final_imid" != */* ]]; then
        final_imid="default/$final_imid"
    else
        local provider_prefix="${final_imid%%/*}"
        if [[ "$provider_prefix" != "default" && "$provider_prefix" != "model2" ]]; then
            final_imid="default/$final_imid"
        fi
    fi

    echo "当前主模型: $final_mid"
    echo "当前图片模型: $final_imid"
    [ -n "$MODEL2_API_KEY" ] && echo "备用提供商: ${MODEL2_NAME:-model2} (已启用)" || true
}

print_runtime_summary() {
    log_section "初始化完成"
    print_model_summary
    echo "API 协议: ${API_PROTOCOL:-openai-completions}"
    echo "Base URL: ${BASE_URL}"
    echo "上下文窗口: ${CONTEXT_WINDOW:-200000}"
    echo "最大 Tokens: ${MAX_TOKENS:-8192}"
    echo "Gateway 端口: $OPENCLAW_GATEWAY_PORT"
    echo "Gateway 绑定: $OPENCLAW_GATEWAY_BIND"
    echo "Gateway 模式: ${OPENCLAW_GATEWAY_MODE:-local}"
    echo "Gateway 允许域: ${OPENCLAW_GATEWAY_ALLOWED_ORIGINS:-未设置}"
    echo "Gateway 允许不安全认证: ${OPENCLAW_GATEWAY_ALLOW_INSECURE_AUTH:-true}"
    echo "Gateway 禁用设备认证: ${OPENCLAW_GATEWAY_DANGEROUSLY_DISABLE_DEVICE_AUTH:-false}"
    echo "插件启用: ${OPENCLAW_PLUGINS_ENABLED:-true}"
    echo "允许插件列表已由系统自动同步"
}

setup_runtime_env() {
    export BUN_INSTALL="/usr/local"
    export PATH="$BUN_INSTALL/bin:$PATH"
    export DBUS_SESSION_BUS_ADDRESS=/dev/null
}

cleanup() {
    echo "=== 接收到停止信号,正在关闭服务 ==="
    if [ -n "$GATEWAY_PID" ]; then
        kill -TERM "$GATEWAY_PID" 2>/dev/null || true
        wait "$GATEWAY_PID" 2>/dev/null || true
    fi
    echo "=== 服务已停止 ==="
    exit 0
}

install_signal_traps() {
    trap cleanup SIGTERM SIGINT SIGQUIT
}

start_gateway() {
    log_section "启动 OpenClaw Gateway"

    gosu node env HOME=/home/node DBUS_SESSION_BUS_ADDRESS=/dev/null \
        BUN_INSTALL="/usr/local" PATH="/usr/local/bin:$PATH" \
        openclaw gateway run \
        --bind "$OPENCLAW_GATEWAY_BIND" \
        --port "$OPENCLAW_GATEWAY_PORT" \
        --token "$OPENCLAW_GATEWAY_TOKEN" \
        --verbose &
    GATEWAY_PID=$!

    echo "=== OpenClaw Gateway 已启动 (PID: $GATEWAY_PID) ==="
}

wait_for_gateway() {
    wait "$GATEWAY_PID"
    local exit_code=$?
    echo "=== OpenClaw Gateway 已退出 (退出码: $exit_code) ==="
    exit "$exit_code"
}

finalize_permissions() {
    if is_root; then
        chown -R node:node "$OPENCLAW_HOME" || true
    fi
}

main() {
    log_section "OpenClaw 初始化脚本"
    ensure_directories
    fix_permissions_if_needed
    sync_config_with_env
    finalize_permissions
    print_runtime_summary
    setup_runtime_env
    install_signal_traps
    start_gateway
    wait_for_gateway
}

main
