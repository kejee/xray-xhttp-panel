#!/bin/bash

# ======================================
# Xray + Reality + XHTTP (纯 IP 开源安全版)
# 特性：50000+安全随机端口、参数指定、状态记忆、BBR加速、完全去敏感化、项目版本显示
# 开源许可: MIT License
# ======================================

set -e

# ========== 全局版本号定义 ==========
VERSION="1.1.0"

# ========== 核心目录定义 ==========
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XRAY_USER="www-data"
XRAY_CONFIG_DIR="/etc/xray"
XRAY_BIN="/usr/local/bin/xray"
XRAY_SERVICE="xray.service"
XRAY_PATH="/opt/xray-panel"
PYTHON="/usr/bin/python3"

# ========== 默认伪装参数 ==========
REALITY_DOMAIN="www.yahoo.com"      
REALITY_DEST="${REALITY_DOMAIN}:443"
XHTTP_DOMAIN="www.yahoo.com"
XHTTP_PATH="/weather"

# ========== 安全随机十六进制生成函数 (兼容无 xxd 的精简环境) ==========
generate_hex() {
    local bytes=$1
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$bytes"
    elif command -v xxd >/dev/null 2>&1; then
        head -c "$bytes" /dev/urandom | xxd -p -c "$bytes" | tr -d " \n"
    elif command -v od >/dev/null 2>&1; then
        od -vN "$bytes" -An -tx1 /dev/urandom | tr -d " \n"
    else
        tr -dc 'a-f0-9' < /dev/urandom | head -c "$((bytes * 2))"
    fi
}

# ========== 账户与安全密钥动态生成 ==========
USER_NAME="admin"
USER_PASSWORD=$(generate_hex 6)
FLASK_SECRET=$(generate_hex 16)

echo "=========================================="
echo " 🌟 欢迎使用 Xray-XHTTP-Panel 一键安装脚本"
echo " 📌 当前项目版本: v$VERSION"
echo "=========================================="

# ========== 端口智能判定逻辑 (参数 -> 记忆/备份 -> 50000+随机) ==========
echo "🔎 正在分析端口配置..."

OLD_XRAY_PORT=""
OLD_PANEL_PORT=""
if [ -f "$XRAY_CONFIG_DIR/config.json" ]; then
    OLD_XRAY_PORT=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG_DIR/config.json" 2>/dev/null || true)
fi
if [ -z "$OLD_XRAY_PORT" ] || [ "$OLD_XRAY_PORT" = "null" ]; then
    if [ -f "$SCRIPT_DIR/xray_full_backup.json" ]; then
        BACKUP_PORT=$(jq -r '.node.port // empty' "$SCRIPT_DIR/xray_full_backup.json" 2>/dev/null || true)
        if [ -n "$BACKUP_PORT" ] && [[ "$BACKUP_PORT" =~ ^[0-9]+$ ]]; then
            OLD_XRAY_PORT=$BACKUP_PORT
            echo "   -> 📦 检测到全量备份文件中的 Xray 节点端口: $OLD_XRAY_PORT"
        fi
    fi
fi
if [ -f "$XRAY_PATH/web/app.py" ]; then
    OLD_PANEL_PORT=$(grep -oP "port=\K[0-9]+" "$XRAY_PATH/web/app.py" 2>/dev/null || true)
fi

generate_random_port() {
    echo $((RANDOM % 15535 + 50000))
}

# 1. 判定面板端口
if [ -n "$1" ] && [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; then
    PANEL_PORT=$1
    echo "   -> 采用命令行指定的面板端口: $PANEL_PORT"
elif [ -n "$OLD_PANEL_PORT" ] && [ "$OLD_PANEL_PORT" != "null" ]; then
    PANEL_PORT=$OLD_PANEL_PORT
    echo "   -> 检测到原有面板端口，已自动记忆继承: $PANEL_PORT"
else
    PANEL_PORT=$(generate_random_port)
    echo "   -> 全新安装且未指定参数，随机生成面板高位端口: $PANEL_PORT"
fi

# 2. 判定 Xray 节点端口
if [ -n "$2" ] && [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -ge 1 ] && [ "$2" -le 65535 ]; then
    XRAY_PORT=$2
    echo "   -> 采用命令行指定的 Xray 端口: $XRAY_PORT"
elif [ -n "$OLD_XRAY_PORT" ] && [ "$OLD_XRAY_PORT" != "null" ]; then
    XRAY_PORT=$OLD_XRAY_PORT
    echo "   -> 检测到原有/备份 Xray 端口，已自动继承: $XRAY_PORT"
else
    XRAY_PORT=$(generate_random_port)
    while [ "$XRAY_PORT" -eq "$PANEL_PORT" ]; do
        XRAY_PORT=$(generate_random_port)
    done
    echo "   -> 全新安装且未指定参数，随机生成 Xray 高位端口: $XRAY_PORT"
fi

# ========== 安装依赖并创建 venv ==========
echo "[1/7] 安装依赖与创建虚拟环境..."
apt update && apt install -y curl wget unzip qrencode python3 python3-venv sqlite3 jq xxd openssl

mkdir -p "$XRAY_PATH"
python3 -m venv "$XRAY_PATH/venv"
source "$XRAY_PATH/venv/bin/activate"
pip install --upgrade pip
pip install flask flask-login flask-session qrcode[pil] requests
deactivate

# ========== 安装 Xray ==========
echo "[2/7] 安装 Xray core..."
mkdir -p "$XRAY_CONFIG_DIR"
wget -O /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip -o /tmp/xray.zip -d /tmp/xray
install -m 755 /tmp/xray/xray "$XRAY_BIN"

# ========== [带记忆与备份恢复功能] 处理 Reality 密钥 ==========
echo "[3/7] 处理 Reality 密钥 (防止重复运行覆盖 / 支持全量备份恢复)..."
KEY_FILE="$XRAY_CONFIG_DIR/.reality_keys"
FULL_BACKUP_FILE="$SCRIPT_DIR/xray_full_backup.json"

if [ -f "$KEY_FILE" ]; then
    source "$KEY_FILE"
elif [ -f "$FULL_BACKUP_FILE" ]; then
    echo "📦 检测到本地全量备份文件 $FULL_BACKUP_FILE，正在提取旧密钥与凭据..."
    PRIVATE_KEY=$(jq -r '.reality.private_key // empty' "$FULL_BACKUP_FILE" 2>/dev/null || true)
    PUBLIC_KEY=$(jq -r '.reality.public_key // empty' "$FULL_BACKUP_FILE" 2>/dev/null || true)
    SHORT_ID=$(jq -r '.reality.short_id // empty' "$FULL_BACKUP_FILE" 2>/dev/null || true)
    if [ -n "$PRIVATE_KEY" ] && [ -n "$PUBLIC_KEY" ] && [ "$PRIVATE_KEY" != "null" ]; then
        echo "✅ 成功从全量备份中提取 Reality 密钥与 ShortId，已保存至备份文件。"
        echo "PRIVATE_KEY=\"$PRIVATE_KEY\"" > "$KEY_FILE"
        echo "PUBLIC_KEY=\"$PUBLIC_KEY\"" >> "$KEY_FILE"
        echo "SHORT_ID=\"$SHORT_ID\"" >> "$KEY_FILE"
        chmod 600 "$KEY_FILE"
    else
        PRIVATE_KEY=""
    fi
elif [ -f "$XRAY_CONFIG_DIR/config.json" ] && [ -f "$XRAY_PATH/web/app.py" ]; then
    PRIVATE_KEY=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$XRAY_CONFIG_DIR/config.json" 2>/dev/null || true)
    SHORT_ID=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$XRAY_CONFIG_DIR/config.json" 2>/dev/null || true)
    PUBLIC_KEY=$(grep -m1 'pubkey = "' "$XRAY_PATH/web/app.py" | awk -F'"' '{print $2}' || true)
    
    if [ -n "$PRIVATE_KEY" ] && [ -n "$PUBLIC_KEY" ] && [ "$PRIVATE_KEY" != "null" ]; then
        echo "PRIVATE_KEY=\"$PRIVATE_KEY\"" > "$KEY_FILE"
        echo "PUBLIC_KEY=\"$PUBLIC_KEY\"" >> "$KEY_FILE"
        echo "SHORT_ID=\"$SHORT_ID\"" >> "$KEY_FILE"
        chmod 600 "$KEY_FILE"
    else
        PRIVATE_KEY="" 
    fi
fi

if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    KEY_JSON=$($XRAY_BIN x25519)
    PRIVATE_KEY=$(echo "$KEY_JSON" | grep -i "Private" | awk -F': ' '{print $2}' | tr -d ' ')
    PUBLIC_KEY=$(echo "$KEY_JSON" | grep -i "Public" | awk -F': ' '{print $2}' | tr -d ' ')
    SHORT_ID=$(generate_hex 8)
    
    echo "PRIVATE_KEY=\"$PRIVATE_KEY\"" > "$KEY_FILE"
    echo "PUBLIC_KEY=\"$PUBLIC_KEY\"" >> "$KEY_FILE"
    echo "SHORT_ID=\"$SHORT_ID\"" >> "$KEY_FILE"
    chmod 600 "$KEY_FILE"
fi

# ========== [带记忆与备份恢复功能] 写入 Xray 配置 ==========
echo "[4/7] 写入 Xray 配置..."
EXISTING_CLIENTS="[]"
if [ -f "$XRAY_CONFIG_DIR/config.json" ]; then
    TMP_CLIENTS=$(jq '.inbounds[0].settings.clients' "$XRAY_CONFIG_DIR/config.json" 2>/dev/null || true)
    if [ -n "$TMP_CLIENTS" ] && [ "$TMP_CLIENTS" != "null" ]; then
        EXISTING_CLIENTS="$TMP_CLIENTS"
    fi
elif [ -f "$FULL_BACKUP_FILE" ]; then
    TMP_CLIENTS=$(jq '.clients // empty' "$FULL_BACKUP_FILE" 2>/dev/null || true)
    if [ -n "$TMP_CLIENTS" ] && [ "$TMP_CLIENTS" != "null" ] && [ "$TMP_CLIENTS" != "[]" ]; then
        EXISTING_CLIENTS="$TMP_CLIENTS"
        echo "✅ 检测到本地全量备份中的用户列表，已自动载入恢复。"
    fi
fi

# 创建 Xray 日志目录
mkdir -p /var/log/xray
chown -R $XRAY_USER:$XRAY_USER /var/log/xray
chmod 755 /var/log/xray

cat > "$XRAY_CONFIG_DIR/config.json" <<EOF
{
  "log": { 
    "loglevel": "warning",
    "access": "/var/log/xray/access.log"
  },
  "stats": {},
  "api": {
    "tag": "api",
    "services": ["StatsService"]
  },
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true
    }
  },
  "inbounds": [
    { 
      "listen": "0.0.0.0",
      "port": $XRAY_PORT,
      "protocol": "vless",
      "settings": {
        "clients": $EXISTING_CLIENTS,
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "$REALITY_DEST",
          "xver": 0,
          "serverNames": ["$REALITY_DOMAIN"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$SHORT_ID"]
        },
        "xhttpSettings": {
          "host": "$XHTTP_DOMAIN",
          "path": "$XHTTP_PATH",
          "mode": "auto"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "metadataOnly": false
      }
    },
    {
      "listen": "127.0.0.1",
      "port": 10085,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      },
      "tag": "api"
    }
  ],
  "routing": {
    "rules": [
      {
        "inboundTag": ["api"],
        "outboundTag": "api",
        "type": "field"
      }
    ]
  },
  "outbounds": [
    { "protocol": "freedom" }
  ]
}
EOF

chown -R $XRAY_USER:$XRAY_USER $XRAY_CONFIG_DIR
chmod 644 $XRAY_CONFIG_DIR/config.json

# ========== 注册 systemd ==========
echo "[5/7] 启用 Xray 服务..."
cat > "/etc/systemd/system/$XRAY_SERVICE" <<EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
ExecStart=$XRAY_BIN run -config $XRAY_CONFIG_DIR/config.json
Restart=on-failure
User=$XRAY_USER

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl enable $XRAY_SERVICE
systemctl restart $XRAY_SERVICE

mkdir -p "$XRAY_PATH/web/templates"

# ========== 后台管理文件 ==========
echo "[6/7] 安装管理后台..."
if [ -f "$XRAY_PATH/web/app.py" ]; then
    OLD_PASS=$(grep -oP 'request.form\['password'\] == "\K[^"]+' "$XRAY_PATH/web/app.py" 2>/dev/null || true)
    if [ -n "$OLD_PASS" ]; then USER_PASSWORD="$OLD_PASS"; fi
    OLD_SECRET=$(grep -oP "app.secret_key = '\K[^']+" "$XRAY_PATH/web/app.py" 2>/dev/null || true)
    if [ -n "$OLD_SECRET" ]; then FLASK_SECRET="$OLD_SECRET"; fi
fi

# 部署流量与在线监控插件 (优先使用本地，若为单文件运行则自动拉取)
if [ -f "$SCRIPT_DIR/stats_plugin.py" ]; then
    cp "$SCRIPT_DIR/stats_plugin.py" "$XRAY_PATH/web/stats_plugin.py"
else
    wget -qO "$XRAY_PATH/web/stats_plugin.py" https://raw.githubusercontent.com/kejee/xray-xhttp-panel/main/stats_plugin.py 2>/dev/null || true
fi

cat > "$XRAY_PATH/web/app.py" <<EOF
from flask import Flask, render_template, request, redirect, url_for, flash, session, send_file, jsonify, Response
from flask_login import LoginManager, login_user, login_required, logout_user, UserMixin
import io
import uuid
import os
import json
import sqlite3
import qrcode
from urllib.parse import quote

app = Flask(__name__)
app.secret_key = '$FLASK_SECRET'
app.jinja_env.filters['urlencode'] = quote

login_manager = LoginManager(app)
login_manager.login_view = 'login'

db_path = os.path.join(os.path.dirname(__file__), 'clients.db')
xray_config = '/etc/xray/config.json'
key_file = '/etc/xray/.reality_keys'

project_version = "$VERSION"
reality_domain = "$REALITY_DOMAIN"
xhttp_domain = "$XHTTP_DOMAIN"
xhttp_path = "$XHTTP_PATH"
pubkey = "$PUBLIC_KEY"
shortid = "$SHORT_ID"

# 引入解耦的流量与在线监控插件 (支持共享流量池与订阅协议)
try:
    from stats_plugin import StatsPlugin
    stats_plugin = StatsPlugin(db_dir=os.path.dirname(__file__), monthly_limit_gb=0)
except Exception as e:
    stats_plugin = None

class User(UserMixin):
    def __init__(self, id): self.id = id

@login_manager.user_loader
def load_user(user_id):
    return User(user_id)

def get_reality_info():
    global pubkey, shortid
    cur_pub = pubkey
    cur_sid = shortid
    cur_priv = ""
    if os.path.exists(key_file):
        try:
            with open(key_file, 'r') as f:
                for line in f:
                    line = line.strip()
                    if line.startswith('PUBLIC_KEY='):
                        cur_pub = line.split('=', 1)[1].strip('"\'')
                    elif line.startswith('SHORT_ID='):
                        cur_sid = line.split('=', 1)[1].strip('"\'')
                    elif line.startswith('PRIVATE_KEY='):
                        cur_priv = line.split('=', 1)[1].strip('"\'')
        except Exception:
            pass
    if os.path.exists(xray_config):
        try:
            with open(xray_config, 'r') as f:
                c = json.load(f)
                r_settings = c.get('inbounds', [{}])[0].get('streamSettings', {}).get('realitySettings', {})
                if r_settings.get('privateKey'):
                    cur_priv = r_settings['privateKey']
                if r_settings.get('shortIds') and len(r_settings['shortIds']) > 0:
                    cur_sid = r_settings['shortIds'][0]
        except Exception:
            pass
    return cur_pub, cur_sid, cur_priv

def get_current_port():
    try:
        with open(xray_config, 'r') as f:
            return json.load(f)['inbounds'][0]['port']
    except:
        return $XRAY_PORT

def get_server_ip():
    try:
        ip = os.popen('curl -s --connect-timeout 2 http://checkip.amazonaws.com || curl -s --connect-timeout 2 https://ifconfig.me').read().strip()
        if ip: return ip
    except:
        pass
    if request and request.host:
        return request.host.split(':')[0]
    return "127.0.0.1"

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        if request.form['username'] == "$USER_NAME" and request.form['password'] == "$USER_PASSWORD":
            login_user(User("$USER_NAME"))
            return redirect(url_for('dashboard'))
        flash("用户名或密码错误")
    return render_template('login.html', version=project_version)

@app.route('/logout')
@login_required
def logout():
    logout_user()
    return redirect(url_for('login'))

@app.route('/')
@login_required
def dashboard():
    with sqlite3.connect(db_path) as conn:
        cur = conn.execute('SELECT id, comment FROM clients')
        rows = [{'id': r[0], 'email': r[1]} for r in cur.fetchall()]
    server_ip = get_server_ip()
    cur_pub, cur_sid, _ = get_reality_info()
    pool_data = stats_plugin.get_stats().get('pool', {}) if stats_plugin else {'used_formatted': '0 B', 'limit_formatted': '无限制', 'limit_gb': 0, 'limit_bytes': 0}
    return render_template('dashboard.html', clients=rows, server_ip=server_ip, port=get_current_port(), pubkey=cur_pub, shortid=cur_sid, reality_domain=reality_domain, xhttp_domain=xhttp_domain, xhttp_path=xhttp_path, version=project_version, pool=pool_data)

@app.route('/sub/<id>')
def client_subscription(id):
    """标准客户端订阅接口 (小火箭 / Clash / v2rayN 通用，注入 Subscription-Userinfo 响应头)"""
    with sqlite3.connect(db_path) as conn:
        row = conn.execute('SELECT comment FROM clients WHERE id = ?', (id,)).fetchone()
        if not row:
            return Response("User Not Found", status=404)
        email = row[0]
    
    server_ip = get_server_ip()
    cur_pub, cur_sid, _ = get_reality_info()
    link = f"vless://{id}@{server_ip}:{get_current_port()}?encryption=none&security=reality&type=xhttp&host={xhttp_domain}&path={xhttp_path}&pbk={cur_pub}&sid={cur_sid}&sni={reality_domain}&fp=chrome#{quote(email)}"
    import base64
    content = base64.b64encode(link.encode('utf-8')).decode('utf-8')
    resp = Response(content, mimetype='text/plain; charset=utf-8')
    
    if stats_plugin:
        sub_header = stats_plugin.get_subscription_info()
        if sub_header:
            resp.headers['Subscription-Userinfo'] = sub_header
            resp.headers['Profile-Update-Interval'] = '24'
    return resp

@app.route('/api/stats')
@login_required
def api_stats():
    if stats_plugin:
        return jsonify(stats_plugin.get_stats())
    return jsonify({"status": "disabled", "online_count": 0, "total_speed_up": "0 B/s", "total_speed_down": "0 B/s", "active_ips": [], "users": {}})

@app.route('/api/reset_stats/<uid>', methods=['POST'])
@login_required
def api_reset_stats(uid):
    if stats_plugin:
        stats_plugin.reset_user_traffic(uid)
        return jsonify({"status": "ok"})
    return jsonify({"status": "disabled"})

@app.route('/change_limit', methods=['POST'])
@login_required
def change_limit():
    new_limit = request.form.get('limit_gb', type=float)
    if new_limit is None or new_limit < 0:
        flash("❌ 限额数值不合法！")
        return redirect(url_for('dashboard'))
    if stats_plugin:
        stats_plugin.set_monthly_limit(new_limit)
        if new_limit == 0:
            flash("✅ 已设为无限流量模式，仅统计已用流量。")
        else:
            flash(f"✅ 月度共享流量限额已更新为 {new_limit:.2f} GB！")
    return redirect(url_for('dashboard'))

@app.route('/change_port', methods=['POST'])
@login_required
def change_port():
    new_port = request.form.get('port', type=int)
    if not new_port or new_port < 1 or new_port > 65535:
        flash("❌ 端口号必须在 1 到 65535 之间！")
        return redirect(url_for('dashboard'))
    try:
        with open(xray_config, 'r') as f: config = json.load(f)
        config['inbounds'][0]['port'] = new_port
        os.system('chown www-data:www-data ' + xray_config)
        with open(xray_config, 'w') as f: json.dump(config, f, indent=2)
        os.system('systemctl restart xray')
        flash(f"✅ Xray 节点端口已成功修改为 {new_port}！请务必在服务器防火墙中放行该新端口。")
    except Exception as e:
        flash(f"❌ 修改端口失败: {str(e)}")
    return redirect(url_for('dashboard'))

@app.route('/add', methods=['POST'])
@login_required
def add():
    uid = str(uuid.uuid4())
    email = request.form.get('email')
    with sqlite3.connect(db_path) as conn:
        conn.execute('INSERT OR IGNORE INTO clients (id, comment) VALUES (?, ?)', (uid, email))
    update_config()
    return redirect(url_for('dashboard'))

@app.route('/delete/<id>')
@login_required
def delete(id):
    with sqlite3.connect(db_path) as conn:
        conn.execute('DELETE FROM clients WHERE id = ?', (id,))
    update_config()
    return redirect(url_for('dashboard'))

@app.route('/qrcode/<id>')
@login_required
def qrcode_img(id):
    with sqlite3.connect(db_path) as conn:
        row = conn.execute('SELECT comment FROM clients WHERE id = ?', (id,)).fetchone()
        email = row[0] if row else 'user'
    server_ip = get_server_ip()
    cur_pub, cur_sid, _ = get_reality_info()
    link = f"vless://{id}@{server_ip}:{get_current_port()}?encryption=none&security=reality&type=xhttp&host={xhttp_domain}&path={xhttp_path}&pbk={cur_pub}&sid={cur_sid}&sni={reality_domain}&fp=chrome#{quote(email)}"
    img = qrcode.make(link)
    buf = io.BytesIO()
    img.save(buf, format='PNG')
    buf.seek(0)
    return send_file(buf, mimetype='image/png')

@app.route('/export')
@login_required
def export_clients():
    with sqlite3.connect(db_path) as conn:
        clients = [{'id': r[0], 'email': r[1]} for r in conn.execute('SELECT id, comment FROM clients').fetchall()]
    
    cur_pub, cur_sid, cur_priv = get_reality_info()
    current_port = get_current_port()
    server_ip = get_server_ip()
    r_target = f"{reality_domain}:443"
    r_sni = reality_domain
    xh_domain = xhttp_domain
    xh_path = xhttp_path

    if os.path.exists(xray_config):
        try:
            with open(xray_config, 'r') as f:
                c = json.load(f)
                inbound = c.get('inbounds', [{}])[0]
                stream = inbound.get('streamSettings', {})
                r_settings = stream.get('realitySettings', {})
                if r_settings.get('target'):
                    r_target = r_settings['target']
                if r_settings.get('serverNames') and len(r_settings['serverNames']) > 0:
                    r_sni = r_settings['serverNames'][0]
                xh_settings = stream.get('xhttpSettings', {})
                if xh_settings.get('host'):
                    xh_domain = xh_settings['host']
                if xh_settings.get('path'):
                    xh_path = xh_settings['path']
        except Exception:
            pass

    import datetime
    backup_data = {
        "version": 2,
        "backup_type": "full",
        "created_at": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "note": "Xray-XHTTP-Panel 纯 IP 版全量恢复备份文件 (含用户列表、Reality 密钥对与端口参数)",
        "node": {
            "port": current_port,
            "host": server_ip
        },
        "reality": {
            "public_key": cur_pub,
            "private_key": cur_priv,
            "short_id": cur_sid,
            "server_names": [r_sni],
            "target": r_target
        },
        "xhttp": {
            "host": xh_domain,
            "path": xh_path
        },
        "clients": clients
    }
    return Response(
        json.dumps(backup_data, indent=2, ensure_ascii=False),
        mimetype='application/json',
        headers={'Content-Disposition': 'attachment;filename=xray_full_backup.json'}
    )

@app.route('/import', methods=['POST'])
@login_required
def import_clients():
    if 'backup_file' not in request.files or request.files['backup_file'].filename == '':
        flash("❌ 未选择任何文件！")
        return redirect(url_for('dashboard'))
    try:
        raw_text = request.files['backup_file'].read().decode('utf-8')
        data = json.loads(raw_text)

        clients = []
        is_full_backup = False
        new_priv = None
        new_pub = None
        new_sid = None
        new_port = None
        new_target = None
        new_sni = None
        new_xh_path = None
        new_xh_domain = None

        if isinstance(data, dict):
            if 'reality' in data or 'backup_type' in data or 'node' in data:
                is_full_backup = True
                clients = data.get('clients', [])
                reality_cfg = data.get('reality', {})
                new_priv = reality_cfg.get('private_key')
                new_pub = reality_cfg.get('public_key')
                new_sid = reality_cfg.get('short_id')
                if reality_cfg.get('target'):
                    new_target = reality_cfg['target']
                if reality_cfg.get('server_names') and len(reality_cfg['server_names']) > 0:
                    new_sni = reality_cfg['server_names'][0]
                node_cfg = data.get('node', {})
                if node_cfg.get('port'):
                    new_port = int(node_cfg['port'])
                xhttp_cfg = data.get('xhttp', {})
                new_xh_path = xhttp_cfg.get('path')
                new_xh_domain = xhttp_cfg.get('host')
            elif 'inbounds' in data:
                inbound = data['inbounds'][0]
                clients = inbound.get('settings', {}).get('clients', [])
                if p := inbound.get('port'):
                    new_port = int(p)
                r_set = inbound.get('streamSettings', {}).get('realitySettings', {})
                if r_set.get('privateKey'):
                    new_priv = r_set['privateKey']
                if r_set.get('shortIds') and len(r_set['shortIds']) > 0:
                    new_sid = r_set['shortIds'][0]
                if r_set.get('target'):
                    new_target = r_set['target']
                if r_set.get('serverNames') and len(r_set['serverNames']) > 0:
                    new_sni = r_set['serverNames'][0]
                xh_set = inbound.get('streamSettings', {}).get('xhttpSettings', {})
                new_xh_path = xh_set.get('path')
                new_xh_domain = xh_set.get('host')
                if new_priv:
                    is_full_backup = True
        elif isinstance(data, list):
            clients = data

        if not clients and not is_full_backup:
            flash("❌ 备份文件内容为空或格式无法识别！")
            return redirect(url_for('dashboard'))

        count = 0
        if clients:
            with sqlite3.connect(db_path) as conn:
                for c in clients:
                    if uid := c.get('id'):
                        email_val = c.get('email') or c.get('comment') or f"导入用户_{uid[:8]}"
                        conn.execute('INSERT OR IGNORE INTO clients (id, comment) VALUES (?, ?)', (uid, email_val))
                        count += 1

        recovered_keys = False
        if is_full_backup or new_priv:
            try:
                if os.path.exists(xray_config):
                    with open(xray_config, 'r') as f:
                        config = json.load(f)
                    
                    inbound = config['inbounds'][0]
                    if new_port and 1 <= new_port <= 65535:
                        inbound['port'] = new_port
                    
                    r_settings = inbound.get('streamSettings', {}).setdefault('realitySettings', {})
                    if new_priv:
                        r_settings['privateKey'] = new_priv
                    if new_sid:
                        r_settings['shortIds'] = [new_sid]
                    if new_target:
                        r_settings['target'] = new_target
                    if new_sni:
                        r_settings['serverNames'] = [new_sni]

                    xh_settings = inbound.get('streamSettings', {}).setdefault('xhttpSettings', {})
                    if new_xh_path:
                        xh_settings['path'] = new_xh_path
                    if new_xh_domain:
                        xh_settings['host'] = new_xh_domain

                    os.system('chown www-data:www-data ' + xray_config)
                    with open(xray_config, 'w') as f:
                        json.dump(config, f, indent=2)

                if new_priv or new_pub or new_sid:
                    key_lines = []
                    if new_priv: key_lines.append(f'PRIVATE_KEY="{new_priv}"')
                    if new_pub: key_lines.append(f'PUBLIC_KEY="{new_pub}"')
                    if new_sid: key_lines.append(f'SHORT_ID="{new_sid}"')
                    if key_lines:
                        with open(key_file, 'w') as kf:
                            kf.write('\\n'.join(key_lines) + '\\n')
                        os.chmod(key_file, 0o600)

                global pubkey, shortid
                if new_pub: pubkey = new_pub
                if new_sid: shortid = new_sid

                recovered_keys = True
            except Exception as e_key:
                print("恢复节点配置异常:", e_key)

        update_config()

        if recovered_keys:
            flash(f"✅ 成功恢复全量配置！已导入 {count} 个用户，并同步恢复了 Reality 密钥、ShortId 及节点端口 ({new_port or get_current_port()})。原客户端无需做任何更改即可直接连接！")
        else:
            flash(f"✅ 成功导入 {count} 个用户！（注意：此备份未包含 Reality 密钥，客户端连接凭据保持当前服务器配置）")
    except Exception as e:
        flash(f"❌ 导入失败: {str(e)}")
    return redirect(url_for('dashboard'))

def update_config():
    with sqlite3.connect(db_path) as conn:
        clients = [{'id': r[0], 'email': r[1]} for r in conn.execute('SELECT id, comment FROM clients').fetchall()]
    with open(xray_config, 'r') as f: config = json.load(f)
    config['inbounds'][0]['settings']['clients'] = clients
    os.system('chown www-data:www-data ' + xray_config)
    with open(xray_config, 'w') as f: json.dump(config, f, indent=2)
    os.system('systemctl restart xray')

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=$PANEL_PORT)
EOF

DB_FILE="$XRAY_PATH/web/clients.db"
touch "$DB_FILE"
chmod 664 "$DB_FILE"

cat > "$XRAY_PATH/web/init.py" <<EOF
import sqlite3
import os
import json
conn = sqlite3.connect("$DB_FILE")
try:
    conn.execute('CREATE TABLE IF NOT EXISTS clients (id TEXT PRIMARY KEY, comment TEXT)')
    conn.commit()
    cur = conn.cursor()
    cur.execute('SELECT count(*) FROM clients')
    if cur.fetchone()[0] == 0 and os.path.exists('$XRAY_CONFIG_DIR/config.json'):
        try:
            with open('$XRAY_CONFIG_DIR/config.json', 'r') as f:
                c_data = json.load(f)
                for c in c_data.get('inbounds', [{}])[0].get('settings', {}).get('clients', []):
                    if c.get('id'):
                        email = c.get('email') or f"user_{c['id'][:8]}"
                        conn.execute('INSERT OR IGNORE INTO clients (id, comment) VALUES (?, ?)', (c['id'], email))
                conn.commit()
        except Exception:
            pass
except: pass
finally: conn.close()
EOF
$PYTHON "$XRAY_PATH/web/init.py"

# 页面模板写入 (login.html)
cat > "$XRAY_PATH/web/templates/login.html" <<'EOF'
<!DOCTYPE html>
<html lang="zh">
<head>
  <meta charset="UTF-8">
  <title>登录后台</title>
  <script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-gray-100 flex flex-col items-center justify-center min-h-screen">
  <div class="bg-white shadow-md rounded px-8 py-6 w-full max-w-sm">
    <h2 class="text-2xl font-bold mb-4 text-center">登录</h2>
    {% with messages = get_flashed_messages() %}
      {% if messages %}
        <div class="bg-red-100 text-red-700 p-2 rounded mb-4 text-sm">
          {% for message in messages %} <p>{{ message }}</p> {% endfor %}
        </div>
      {% endif %}
    {% endwith %}
    <form method="post" class="space-y-4">
      <div>
        <label class="block text-sm font-medium text-gray-700">用户名</label>
        <input type="text" name="username" required class="w-full px-3 py-2 border rounded shadow-sm">
      </div>
      <div>
        <label class="block text-sm font-medium text-gray-700">密码</label>
        <input type="password" name="password" required class="w-full px-3 py-2 border rounded shadow-sm">
      </div>
      <button type="submit" class="w-full bg-blue-600 text-white py-2 rounded hover:bg-blue-700">登录</button>
    </form>
  </div>
  <p class="text-xs text-gray-400 mt-4">Xray-XHTTP-Panel v{{ version }}</p>
</body>
</html>
EOF

# 页面模板写入 (dashboard.html)
cat > "$XRAY_PATH/web/templates/dashboard.html" <<'EOF'
<!DOCTYPE html>
<html lang="zh">
<head>
  <meta charset="UTF-8">
  <title>管理后台</title>
  <script src="https://cdn.tailwindcss.com"></script>
  <script>
    function copyText(text, successMsg) {
      if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(text).then(() => alert(successMsg || "✅ 已复制到剪贴板！"))
        .catch(() => fallbackCopyText(text, successMsg));
      } else { fallbackCopyText(text, successMsg); }
    }
    function fallbackCopyText(text, successMsg) {
      const ta = document.createElement('textarea');
      ta.value = text;
      document.body.appendChild(ta);
      ta.select();
      try { document.execCommand('copy') ? alert(successMsg || "✅ 已复制！") : alert("❌ 请手动复制！"); } 
      catch (e) { alert("❌ 浏览器不支持，请手动复制！"); }
      document.body.removeChild(ta);
    }
    function copyLink(uuid) {
      const input = document.getElementById('link-' + uuid);
      copyText(input.value, "✅ 已复制 VLESS 节点链接！");
    }
    function copySub(uuid) {
      const subUrl = window.location.origin + '/sub/' + uuid;
      copyText(subUrl, "✅ 已复制通用订阅链接！可直接导入小火箭 / Clash / v2rayN");
    }
    async function resetTraffic(uid, name) {
      if (!confirm(`确定要重置用户【${name}】的流量统计吗？`)) return;
      try {
        const res = await fetch('/api/reset_stats/' + uid, { method: 'POST' });
        const data = await res.json();
        if (data.status === 'ok') {
          alert('✅ 流量统计已重置！');
          updateStats();
        } else {
          alert('❌ 重置失败');
        }
      } catch (e) { alert('❌ 请求异常: ' + e); }
    }
  </script>
</head>
<body class="bg-gray-50 text-gray-800">
  <div class="max-w-4xl mx-auto py-8 px-4">
    <h1 class="text-3xl font-bold mb-6">管理后台</h1>
    {% with messages = get_flashed_messages() %}
      {% if messages %}
        <div class="bg-blue-100 border-l-4 border-blue-500 text-blue-700 p-4 mb-4 shadow-sm">
          {% for message in messages %} <p>{{ message }}</p> {% endfor %}
        </div>
      {% endif %}
    {% endwith %}

    <!-- 实时指标卡片 -->
    <div class="grid grid-cols-1 sm:grid-cols-3 gap-4 mb-6">
      <div class="bg-white p-4 rounded-lg shadow border-l-4 border-emerald-500 flex items-center justify-between">
        <div>
          <p class="text-xs text-gray-500 font-medium">实时下行速率</p>
          <p class="text-xl font-bold text-gray-800 font-mono mt-1" id="total-speed-down">0 B/s</p>
        </div>
        <span class="text-2xl">📥</span>
      </div>
      <div class="bg-white p-4 rounded-lg shadow border-l-4 border-blue-500 flex items-center justify-between">
        <div>
          <p class="text-xs text-gray-500 font-medium">实时上行速率</p>
          <p class="text-xl font-bold text-gray-800 font-mono mt-1" id="total-speed-up">0 B/s</p>
        </div>
        <span class="text-2xl">📤</span>
      </div>
      <div class="bg-white p-4 rounded-lg shadow border-l-4 border-indigo-500 flex items-center justify-between">
        <div>
          <p class="text-xs text-gray-500 font-medium">在线设备数</p>
          <p class="text-xl font-bold text-gray-800 font-mono mt-1"><span id="online-count">0</span> 台</p>
        </div>
        <span class="text-2xl">📱</span>
      </div>
    </div>

    <!-- 物理设备连接详情 (折叠展示) -->
    <div class="mb-6 bg-white shadow rounded-lg p-4 border border-gray-100 text-sm">
      <div class="flex justify-between items-center cursor-pointer" onclick="document.getElementById('active-ips-container').classList.toggle('hidden')">
        <span class="font-medium text-gray-700">👥 当前连入的外部设备 IP 列表</span>
        <span class="text-xs text-blue-600 hover:underline">展开/折叠 ▼</span>
      </div>
      <div id="active-ips-container" class="mt-3 pt-3 border-t border-gray-100 flex flex-wrap gap-2 text-xs">
        <span class="text-gray-400 italic">暂无设备连入</span>
      </div>
    </div>

    <div class="mb-6 bg-white shadow rounded-lg p-4 flex flex-col md:flex-row gap-4 items-center justify-between border-l-4 border-blue-500">
      <div><p class="text-base">服务器 IP：<span class="font-mono text-green-700 font-semibold">{{ server_ip }}</span></p></div>
      <form method="post" action="/change_port" class="flex items-center gap-2">
        <label class="text-gray-700 text-sm font-medium">节点端口：</label>
        <input type="number" name="port" value="{{ port }}" min="1" max="65535" required class="border px-2 py-1 rounded w-24 text-center focus:ring focus:border-blue-300 text-sm" />
        <button type="submit" class="bg-blue-500 text-white px-3 py-1 rounded hover:bg-blue-600 shadow-sm transition text-sm">💾 修改端口</button>
      </form>
    </div>

    <!-- 月度流量统计与限额设置 -->
    <div class="mb-6 bg-white shadow rounded-lg p-4 border-l-4 border-violet-500">
      <div class="flex flex-col md:flex-row justify-between items-start md:items-center gap-4">
        <div>
          <div class="flex items-center gap-2">
            <span class="text-xs text-gray-500 font-medium">本月已用流量</span>
            <span id="pool-limit-badge" class="text-xs px-2 py-0.5 rounded-full font-medium {% if pool and pool.limit_gb > 0 %}bg-blue-100 text-blue-700{% else %}bg-green-100 text-green-700{% endif %}">
              {% if pool and pool.limit_gb > 0 %}限额 {{ pool.limit_formatted }} (剩 {{ pool.remaining_formatted }}){% else %}无限流量 (不设限){% endif %}
            </span>
          </div>
          <p class="text-2xl font-bold font-mono text-gray-800 mt-1" id="pool-used">{{ pool.used_formatted if pool else '0 B' }}</p>
        </div>
        
        <form method="post" action="/change_limit" class="flex items-center gap-2 flex-wrap">
          <label class="text-gray-700 text-sm font-medium">月度限额 (GB)：</label>
          <input type="number" name="limit_gb" step="1" min="0" value="{{ pool.limit_gb if pool else 0 }}" class="border px-2 py-1 rounded w-24 text-center text-sm focus:ring focus:border-violet-300 font-mono" placeholder="0为不限" />
          <button type="submit" class="bg-violet-600 text-white px-3 py-1 rounded hover:bg-violet-700 shadow-sm transition text-sm">💾 保存限额</button>
        </form>
      </div>

      <!-- 限额进度条 (若设置限额则显示，未设置隐藏) -->
      <div id="pool-progress-container" class="mt-3 {% if not pool or pool.limit_gb <= 0 %}hidden{% endif %}">
        <div class="w-full bg-gray-200 rounded-full h-2 overflow-hidden">
          <div id="pool-progress-bar" class="h-2 rounded-full transition-all duration-500 {% if pool and pool.status == 'danger' %}bg-red-500{% elif pool and pool.status == 'warning' %}bg-amber-500{% else %}bg-blue-500{% endif %}" style="width: {{ [pool.percent if pool else 0, 100]|min }}%;"></div>
        </div>
      </div>
      <p class="text-xs text-gray-400 mt-2">💡 设为 <b>0</b> 时为无限流量，仅统计已用流量；输入具体数值（如 100）将开启超额预警与进度条。</p>
    </div>

    <h2 class="text-2xl font-semibold mb-3">用户列表</h2>
    <ul class="space-y-4">
      {% for client in clients %}
      <li class="bg-white shadow rounded-lg p-4 border border-gray-100 transition hover:shadow-md">
        <div class="flex justify-between items-start gap-4">
          <div class="flex-1">
            <div class="flex items-center gap-2 flex-wrap">
              <span class="font-bold text-gray-800 text-base">{{ client.email }}</span>
              <span id="badge-{{ client.id }}" class="text-xs px-2 py-0.5 rounded-full bg-gray-100 text-gray-500">离线</span>
            </div>
            <p class="text-xs font-mono text-gray-400 mt-1 break-all">UUID: {{ client.id }}</p>
            
            <!-- 流量统计指标 -->
            <div class="mt-3 flex flex-wrap gap-4 text-xs text-gray-600 bg-gray-50 p-2.5 rounded border border-gray-100 font-mono">
              <div>下行总计: <span id="down-{{ client.id }}" class="font-semibold text-gray-800">0 B</span></div>
              <div>上行总计: <span id="up-{{ client.id }}" class="font-semibold text-gray-800">0 B</span></div>
              <div>实时速率: <span id="speed-{{ client.id }}" class="font-semibold text-indigo-600">↓ 0 B/s | ↑ 0 B/s</span></div>
              <div>本次会话: <span id="session-{{ client.id }}" class="text-gray-500">0秒 (0 B)</span></div>
            </div>
          </div>
          <div class="flex gap-2 text-xs flex-wrap justify-end">
            <button onclick="copySub('{{ client.id }}')" class="text-indigo-600 hover:text-indigo-800 bg-indigo-50 px-2 py-1 rounded border border-indigo-100 hover:bg-indigo-100 transition">📋 订阅</button>
            <a href="/qrcode/{{ client.id }}" target="_blank" class="text-blue-600 hover:text-blue-800 bg-blue-50 px-2 py-1 rounded border border-blue-100 hover:bg-blue-100 transition">📱 二维码</a>
            <button onclick="resetTraffic('{{ client.id }}', '{{ client.email }}')" class="text-amber-600 hover:text-amber-800 bg-amber-50 px-2 py-1 rounded border border-amber-100 hover:bg-amber-100 transition">🔄 清零</button>
            <a href="/delete/{{ client.id }}" onclick="return confirm('确定要删除吗？')" class="text-red-600 hover:text-red-800 bg-red-50 px-2 py-1 rounded border border-red-100 hover:bg-red-100 transition">❌ 删除</a>
          </div>
        </div>
        <div class="mt-3">
          <input id="link-{{ client.id }}" type="text"
            class="w-full border px-2 py-1 rounded text-xs font-mono text-gray-700 bg-gray-50 focus:outline-none"
            value="vless://{{ client.id }}@{{ server_ip }}:{{ port }}?encryption=none&security=reality&type=xhttp&host={{ xhttp_domain }}&path={{ xhttp_path }}&pbk={{ pubkey }}&sid={{ shortid }}&sni={{ reality_domain }}&fp=chrome#{{ client.email | urlencode }}" readonly />
          <button onclick="copyLink('{{ client.id }}')" class="mt-2 px-3 py-1 bg-blue-500 text-white text-xs rounded hover:bg-blue-600 shadow-sm transition">📋 复制节点链接</button>
        </div>
      </li>
      {% endfor %}
    </ul>

    <h2 class="text-xl font-semibold mt-8 mb-3">添加新用户</h2>
    <form method="post" action="/add" class="flex gap-4 flex-wrap items-center bg-white shadow rounded-lg p-4 border border-gray-100">
      <input type="text" name="email" placeholder="输入标识（支持中文）" required class="flex-1 border px-3 py-2 rounded text-sm w-full sm:w-auto focus:ring focus:border-green-300" />
      <button type="submit" class="bg-green-500 text-white px-6 py-2 rounded text-sm hover:bg-green-600 shadow-sm transition">➕ 添加</button>
    </form>

    <h2 class="text-xl font-semibold mt-8 mb-3">数据备份与全量恢复</h2>
    <div class="bg-white shadow rounded-lg p-5 border border-gray-100 flex flex-col gap-4">
      <div class="flex flex-col md:flex-row gap-6 items-center justify-between">
        <a href="/export" class="bg-purple-600 text-white px-5 py-2.5 rounded text-sm font-medium hover:bg-purple-700 shadow-sm text-center w-full md:w-auto transition flex items-center justify-center gap-2">
          <span>💾 导出全量配置备份 (含密钥/端口/用户)</span>
        </a>
        <div class="hidden md:block w-px h-10 bg-gray-200"></div>
        <form method="post" action="/import" enctype="multipart/form-data" class="flex flex-1 gap-2 flex-col sm:flex-row w-full items-center">
          <input type="file" name="backup_file" accept=".json" required class="border px-3 py-1.5 rounded text-xs flex-1 bg-gray-50 file:mr-2 file:py-1 file:px-2 file:rounded file:border-0 file:text-xs file:bg-indigo-50 file:text-indigo-700 hover:file:bg-indigo-100" />
          <button type="submit" class="bg-amber-500 text-white px-5 py-2 rounded text-sm font-medium hover:bg-amber-600 shadow-sm text-center transition w-full sm:w-auto">📂 恢复配置 JSON</button>
        </form>
      </div>
      <p class="text-xs text-gray-500 leading-relaxed bg-slate-50 p-2.5 rounded border border-slate-100">
        💡 <b>无损恢复说明</b>：全量备份自动打包所有用户、Reality 密钥对（私钥/公钥/ShortId）、节点运行端口与混淆伪装配置。在任何新服务器导入此文件后，原有客户端<b>无需重新配置或扫码</b>，即可直接恢复连通。同时向下兼容旧版纯用户 JSON 导入。
      </p>
    </div>

    <div class="mt-8 mb-8 flex justify-between items-center border-t pt-4 text-xs text-gray-400">
      <a href="/logout" class="text-gray-500 hover:text-gray-800 hover:underline">🚪 退出登录</a>
      <span>Powered by Xray-XHTTP-Panel v{{ version }}</span>
    </div>
  </div>

  <script>
    async function updateStats() {
      try {
        const res = await fetch('/api/stats');
        const data = await res.json();
        if (data.status === 'ok') {
          const elDown = document.getElementById('total-speed-down');
          const elUp = document.getElementById('total-speed-up');
          const elCount = document.getElementById('online-count');
          if (elDown) elDown.innerText = data.total_speed_down;
          if (elUp) elUp.innerText = data.total_speed_up;
          if (elCount) elCount.innerText = (data.active_user_count !== undefined) ? data.active_user_count : data.online_count;

          const ipBox = document.getElementById('active-ips-container');
          if (ipBox && data.active_ips) {
            if (data.active_ips.length === 0) {
              ipBox.innerHTML = '<span class="text-gray-400 italic">暂无设备连入</span>';
            } else {
              ipBox.innerHTML = data.active_ips.map(ip => `<span class="bg-green-50 text-green-700 border border-green-200 px-2 py-0.5 rounded font-mono">${ip}</span>`).join('');
            }
          }

          if (data.pool) {
            const elPoolUsed = document.getElementById('pool-used');
            const elBadge = document.getElementById('pool-limit-badge');
            const elProgCont = document.getElementById('pool-progress-container');
            const elProg = document.getElementById('pool-progress-bar');
            
            if (elPoolUsed) elPoolUsed.innerText = data.pool.used_formatted;
            
            if (data.pool.limit_gb > 0) {
              if (elBadge) {
                elBadge.className = 'text-xs px-2 py-0.5 rounded-full font-medium bg-blue-100 text-blue-700';
                elBadge.innerText = `限额 ${data.pool.limit_formatted} (剩 ${data.pool.remaining_formatted})`;
              }
              if (elProgCont) elProgCont.classList.remove('hidden');
              if (elProg) {
                elProg.style.width = Math.min(100, data.pool.percent) + '%';
                elProg.className = `h-2 rounded-full transition-all duration-500 ${data.pool.status === 'danger' ? 'bg-red-500' : (data.pool.status === 'warning' ? 'bg-amber-500' : 'bg-blue-500')}`;
              }
            } else {
              if (elBadge) {
                elBadge.className = 'text-xs px-2 py-0.5 rounded-full font-medium bg-green-100 text-green-700';
                elBadge.innerText = '无限流量 (不设限)';
              }
              if (elProgCont) elProgCont.classList.add('hidden');
            }
          }

          if (data.users) {
            for (const [uid, u] of Object.entries(data.users)) {
              const elD = document.getElementById('down-' + uid);
              const elU = document.getElementById('up-' + uid);
              const elS = document.getElementById('speed-' + uid);
              const elSess = document.getElementById('session-' + uid);
              const elBadge = document.getElementById('badge-' + uid);

              if (elD) elD.innerText = u.total_down_formatted;
              if (elU) elU.innerText = u.total_up_formatted;
              if (elS) elS.innerText = `↓ ${u.speed_down_formatted} | ↑ ${u.speed_up_formatted}`;
              if (elSess) elSess.innerText = `${u.session_duration_formatted} (${u.session_traffic_formatted})`;

              if (elBadge) {
                if (u.is_online) {
                  elBadge.className = 'text-xs px-2 py-0.5 rounded-full bg-green-100 text-green-700 font-medium animate-pulse';
                  elBadge.innerText = '在线传输中';
                } else if (u.last_active_human && u.last_active_human !== '刚刚活跃') {
                  elBadge.className = 'text-xs px-2 py-0.5 rounded-full bg-gray-100 text-gray-500';
                  elBadge.innerText = u.last_active_human;
                } else {
                  elBadge.className = 'text-xs px-2 py-0.5 rounded-full bg-gray-100 text-gray-500';
                  elBadge.innerText = '离线';
                }
              }
            }
          }
        }
      } catch (e) {
        console.error("更新统计数据失败", e);
      }
    }

    setInterval(updateStats, 3000);
    updateStats();
  </script>
</body>
</html>
EOF

# ========== systemd 启动后台 ==========
echo "[7/7] 启动面板与开启内核调优..."
cat > /etc/systemd/system/xray-panel.service <<EOF
[Unit]
Description=Xray 后台面板
After=network.target

[Service]
WorkingDirectory=$XRAY_PATH/web
ExecStart=$XRAY_PATH/venv/bin/python $XRAY_PATH/web/app.py
Restart=on-failure
RestartSec=5s
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl restart xray-panel
systemctl enable xray-panel

# ========== [系统调优] 开启 BBR 网络加速 ==========
if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
  echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
  sysctl -p >/dev/null 2>&1
fi

SERVER_IP=$(curl -s http://checkip.amazonaws.com)

echo "=========================================="
echo "✅ 开源安全版一键部署完成！"
echo "------------------------------------------"
echo "📌 项目版本：v$VERSION"
echo "🔗 访问管理面板：http://$SERVER_IP:$PANEL_PORT"
echo "👤 登录账号：$USER_NAME"
echo "🔑 动态登录密码：$USER_PASSWORD"
echo "------------------------------------------"
echo "📌 Xray 初始节点端口：$XRAY_PORT"
echo "⚠️ 防火墙重要提醒："
echo "   请确保您的云服务器后台已放行 TCP 端口： 22, $PANEL_PORT 和 $XRAY_PORT"
echo "   (或者直接在云平台放行 50000-65535 的高位端口池规则)"
echo "=========================================="