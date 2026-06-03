#!/bin/bash

# ======================================
# Xray + Reality + XHTTP (纯 IP 开源安全版)
# 特性：50000+安全随机端口、参数指定、状态记忆、BBR加速、完全去敏感化、项目版本显示
# 开源许可: MIT License
# ======================================

set -e

# ========== 全局版本号定义 ==========
VERSION="1.0.0"

# ========== 核心目录定义 ==========
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

# ========== 账户与安全密钥动态生成 ==========
USER_NAME="admin"
USER_PASSWORD=$(head -c 16 /dev/urandom | xxd -ps | head -c 12)
FLASK_SECRET=$(head -c 16 /dev/urandom | xxd -ps)

echo "=========================================="
echo " 🌟 欢迎使用 Xray-XHTTP-Panel 一键安装脚本"
echo " 📌 当前项目版本: v$VERSION"
echo "=========================================="

# ========== 端口智能判定逻辑 (参数 -> 记忆 -> 50000+随机) ==========
echo "🔎 正在分析端口配置..."

OLD_XRAY_PORT=""
OLD_PANEL_PORT=""
if [ -f "$XRAY_CONFIG_DIR/config.json" ]; then
    OLD_XRAY_PORT=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG_DIR/config.json" 2>/dev/null || true)
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
    echo "   -> 检测到原有 Xray 端口，已自动记忆继承: $XRAY_PORT"
else
    XRAY_PORT=$(generate_random_port)
    while [ "$XRAY_PORT" -eq "$PANEL_PORT" ]; do
        XRAY_PORT=$(generate_random_port)
    done
    echo "   -> 全新安装且未指定参数，随机生成 Xray 高位端口: $XRAY_PORT"
fi

# ========== 安装依赖并创建 venv ==========
echo "[1/7] 安装依赖与创建虚拟环境..."
apt update && apt install -y curl wget unzip qrencode python3 python3-venv sqlite3 jq

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

# ========== [带记忆功能] 处理 Reality 密钥 ==========
echo "[3/7] 处理 Reality 密钥 (防止重复运行覆盖)..."
KEY_FILE="$XRAY_CONFIG_DIR/.reality_keys"

if [ -f "$KEY_FILE" ]; then
    source "$KEY_FILE"
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
    SHORT_ID=$(head -c 8 /dev/urandom | xxd -ps)
    
    echo "PRIVATE_KEY=\"$PRIVATE_KEY\"" > "$KEY_FILE"
    echo "PUBLIC_KEY=\"$PUBLIC_KEY\"" >> "$KEY_FILE"
    echo "SHORT_ID=\"$SHORT_ID\"" >> "$KEY_FILE"
    chmod 600 "$KEY_FILE"
fi

# ========== [带记忆功能] 写入 Xray 配置 ==========
echo "[4/7] 写入 Xray 配置..."
EXISTING_CLIENTS="[]"
if [ -f "$XRAY_CONFIG_DIR/config.json" ]; then
    TMP_CLIENTS=$(jq '.inbounds[0].settings.clients' "$XRAY_CONFIG_DIR/config.json" 2>/dev/null || true)
    if [ -n "$TMP_CLIENTS" ] && [ "$TMP_CLIENTS" != "null" ]; then
        EXISTING_CLIENTS="$TMP_CLIENTS"
    fi
fi

cat > "$XRAY_CONFIG_DIR/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
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
    }
  ],
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

project_version = "$VERSION"
reality_domain = "$REALITY_DOMAIN"
xhttp_domain = "$XHTTP_DOMAIN"
xhttp_path = "$XHTTP_PATH"
pubkey = "$PUBLIC_KEY"
shortid = "$SHORT_ID"

class User(UserMixin):
    def __init__(self, id): self.id = id

@login_manager.user_loader
def load_user(user_id):
    return User(user_id)

def get_current_port():
    try:
        with open(xray_config, 'r') as f:
            return json.load(f)['inbounds'][0]['port']
    except:
        return $XRAY_PORT

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
    server_ip = os.popen('curl -s http://checkip.amazonaws.com').read().strip()
    return render_template('dashboard.html', clients=rows, server_ip=server_ip, port=get_current_port(), pubkey=pubkey, shortid=shortid, reality_domain=reality_domain, xhttp_domain=xhttp_domain, xhttp_path=xhttp_path, version=project_version)

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
        flash(f"✅ Xray 节点端口已成功修改为 {new_port}！")
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
    server_ip = os.popen('curl -s http://checkip.amazonaws.com').read().strip()
    link = f"vless://{id}@{server_ip}:{get_current_port()}?encryption=none&security=reality&type=xhttp&host={xhttp_domain}&path={xhttp_path}&pbk={pubkey}&sid={shortid}&sni={reality_domain}&fp=chrome#{quote(email)}"
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
    return Response(json.dumps(clients, indent=2), mimetype='application/json', headers={'Content-Disposition': 'attachment;filename=xray_clients_backup.json'})

@app.route('/import', methods=['POST'])
@login_required
def import_clients():
    if 'backup_file' not in request.files or request.files['backup_file'].filename == '':
        flash("❌ 未选择任何 file！")
        return redirect(url_for('dashboard'))
    try:
        data = json.loads(request.files['backup_file'].read().decode('utf-8'))
        clients = data['inbounds'][0]['settings']['clients'] if isinstance(data, dict) and 'inbounds' in data else (data if isinstance(data, list) else [])
        if not clients: return redirect(url_for('dashboard'))
        count = 0
        with sqlite3.connect(db_path) as conn:
            for c in clients:
                if uid := c.get('id'):
                    conn.execute('INSERT OR IGNORE INTO clients (id, comment) VALUES (?, ?)', (uid, c.get('email', f"导入用户_{uid[:8]}")))
                    count += 1
        update_config()
        flash(f"✅ 成功导入 {count} 个用户！")
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
conn = sqlite3.connect("$DB_FILE")
try:
    conn.execute('CREATE TABLE IF NOT EXISTS clients (id TEXT PRIMARY KEY, comment TEXT)')
    conn.commit()
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

# 页面模板写入 (dashboard.html) 包含页脚版本信息
cat > "$XRAY_PATH/web/templates/dashboard.html" <<'EOF'
<!DOCTYPE html>
<html lang="zh">
<head>
  <meta charset="UTF-8">
  <title>管理后台</title>
  <script src="https://cdn.tailwindcss.com"></script>
  <script>
    function copyLink(uuid) {
      const input = document.getElementById('link-' + uuid);
      if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(input.value).then(() => alert("✅ 已复制链接到剪贴板！"))
        .catch(() => fallbackCopy(input));
      } else { fallbackCopy(input); }
    }
    function fallbackCopy(inputElement) {
      inputElement.select(); inputElement.setSelectionRange(0, 99999);
      try { document.execCommand('copy') ? alert("✅ 已复制！") : alert("❌ 请手动复制！"); } 
      catch (e) { alert("❌ 浏览器不支持，请手动复制！"); }
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

    <div class="mb-6 bg-white shadow rounded p-4 flex flex-col md:flex-row gap-4 items-center justify-between border-l-4 border-blue-500">
      <div><p class="text-lg">服务器 IP：<span class="font-mono text-green-700">{{ server_ip }}</span></p></div>
      <form method="post" action="/change_port" class="flex items-center gap-2">
        <label class="text-gray-700 font-medium">节点端口：</label>
        <input type="number" name="port" value="{{ port }}" min="1" max="65535" required class="border px-2 py-1 rounded w-24 text-center focus:ring focus:border-blue-300" />
        <button type="submit" class="bg-blue-500 text-white px-3 py-1 rounded hover:bg-blue-600 shadow-sm transition">💾 修改端口</button>
      </form>
    </div>

    <h2 class="text-2xl font-semibold mb-3">用户列表</h2>
    <ul class="space-y-6">
      {% for client in clients %}
      <li class="bg-white shadow rounded p-4 border border-gray-100">
        <div class="flex justify-between items-start gap-4">
          <div class="flex-1">
            <p class="font-semibold">{{ client.email }}</p>
            <p class="text-sm break-all text-gray-600">UUID: {{ client.id }}</p>
          </div>
          <div class="flex gap-4">
            <a href="/qrcode/{{ client.id }}" target="_blank" class="text-blue-600 hover:underline">📱 二维码</a>
            <a href="/delete/{{ client.id }}" onclick="return confirm('确定要删除吗？')" class="text-red-600 hover:underline">❌ 删除</a>
          </div>
        </div>
        <div class="mt-3">
          <input id="link-{{ client.id }}" type="text"
            class="w-full border px-2 py-1 rounded text-sm font-mono text-gray-700 bg-gray-50"
            value="vless://{{ client.id }}@{{ server_ip }}:{{ port }}?encryption=none&security=reality&type=xhttp&host={{ xhttp_domain }}&path={{ xhttp_path }}&pbk={{ pubkey }}&sid={{ shortid }}&sni={{ reality_domain }}&fp=chrome#{{ client.email | urlencode }}" readonly />
          <button onclick="copyLink('{{ client.id }}')" class="mt-2 px-3 py-1 bg-blue-500 text-white text-sm rounded hover:bg-blue-600 shadow-sm transition">📋 复制链接</button>
        </div>
      </li>
      {% endfor %}
    </ul>

    <h2 class="text-xl font-semibold mt-8 mb-3">添加新用户</h2>
    <form method="post" action="/add" class="flex gap-4 flex-wrap items-center bg-white shadow rounded p-4 border border-gray-100">
      <input type="text" name="email" placeholder="输入标识（支持中文）" required class="flex-1 border px-3 py-2 rounded w-full sm:w-auto focus:ring focus:border-green-300" />
      <button type="submit" class="bg-green-500 text-white px-6 py-2 rounded hover:bg-green-600 shadow-sm transition">➕ 添加</button>
    </form>

    <h2 class="text-xl font-semibold mt-8 mb-3">数据备份与恢复</h2>
    <div class="bg-white shadow rounded p-4 flex flex-col md:flex-row gap-6 items-center border border-gray-100">
      <a href="/export" class="bg-purple-500 text-white px-4 py-2 rounded hover:bg-purple-600 shadow-sm text-center w-full md:w-auto transition">💾 备份/导出用户</a>
      <div class="hidden md:block w-px h-10 bg-gray-200"></div>
      <form method="post" action="/import" enctype="multipart/form-data" class="flex flex-1 gap-2 flex-col sm:flex-row w-full">
        <input type="file" name="backup_file" accept=".json" required class="border px-2 py-1 rounded text-sm flex-1 bg-gray-50" />
        <button type="submit" class="bg-yellow-500 text-white px-4 py-2 rounded hover:bg-yellow-600 shadow-sm text-center transition">📂 导入 JSON</button>
      </form>
    </div>

    <div class="mt-8 mb-8 flex justify-between items-center border-t pt-4 text-xs text-gray-400">
      <a href="/logout" class="text-gray-500 hover:text-gray-800 hover:underline">🚪 退出登录</a>
      <span>Powered by Xray-XHTTP-Panel v{{ version }}</span>
    </div>
  </div>
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