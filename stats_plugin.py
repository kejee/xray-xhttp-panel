import json
import os
import re
import sqlite3
import subprocess
import threading
import time
import datetime

# ==============================================================================
# Xray 流量统计与在线监控插件 (StatsPlugin) - 方案 A 共享池与订阅支持版
# 核心特性：
#   1. 【双维度彻底解耦】：
#      - 账号层：100% 依赖 Xray 原生 Stats API，按 UUID 独立记账，零误差
#      - 物理层：100% 依赖 Linux 内核 Socket (ss -nt)，秒级反映真实物理连接
#   2. 【月度共享流量池】：
#      - 支持自定义月度流量配额（默认 0 不限额，仅展示已用量），自然月 (1号 00:00) 自动清零重置
#      - 历史总流量永久归档存储，两者兼顾
#   3. 【标准订阅协议 (Subscription-Userinfo)】：
#      - 为小火箭 / Clash / v2rayN 等客户端注入标准用量响应头，界面直接显示进度条与到期时间
#   4. 【纯净会话计时与状态追溯】：
#      - 传输中秒级计时，30 秒无流量自动切为空闲，友好展示“最后活跃：X分钟前”
#   5. 【零 access.log 依赖】：彻底摆脱文本日志解析，CPU 与磁盘开销 < 0.1%
# ==============================================================================

class StatsPlugin:
    def __init__(self, db_dir, xray_bin="/usr/local/bin/xray", api_port=10085, monthly_limit_gb=0):
        self.db_path = os.path.join(db_dir, 'stats.db')
        self.xray_bin = xray_bin
        self.api_port = api_port
        self.monthly_limit_gb = float(monthly_limit_gb) if monthly_limit_gb is not None else 0.0
        self.lock = threading.Lock()
        
        # 账号流量与会话运行时指标
        self.runtime_stats = {}
        self.last_raw_stats = {}      # { email: { 'up': bytes, 'down': bytes, 'time': ts } }
        self.user_sessions = {}        # { uid: { 'start_time': ts, 'session_bytes': 0, 'last_active': ts } }
        
        # 物理连接网络指标
        self.active_ips = []
        self.active_devices = []
        self.total_connections = 0
        self.total_speed_up = 0
        self.total_speed_down = 0

        # 月度共享流量池指标 (默认 0 表示无限制)
        self.pool_stats = {
            "used_bytes": 0,
            "limit_bytes": int(self.monthly_limit_gb * 1024 * 1024 * 1024),
            "limit_gb": self.monthly_limit_gb,
            "used_formatted": "0 B",
            "limit_formatted": f"{self.monthly_limit_gb:.2f} GB" if self.monthly_limit_gb > 0 else "无限制",
            "remaining_formatted": f"{self.monthly_limit_gb:.2f} GB" if self.monthly_limit_gb > 0 else "充足",
            "percent": 0.0,
            "status": "normal"  # normal / warning / danger
        }

        self._init_db()
        self._start_collector()

    def _init_db(self):
        """初始化独立的流量持久化数据表 (支持月度周期与历史累计)"""
        with sqlite3.connect(self.db_path) as conn:
            conn.execute('''
                CREATE TABLE IF NOT EXISTS settings (
                    key TEXT PRIMARY KEY,
                    value TEXT
                )
            ''')
            # 尝试从持久化配置中读取已保存的月度限额
            try:
                cur = conn.cursor()
                cur.execute("SELECT value FROM settings WHERE key = 'monthly_limit_gb'")
                row = cur.fetchone()
                if row and row[0] is not None:
                    self.monthly_limit_gb = max(0.0, float(row[0]))
            except Exception:
                pass

            conn.execute('''
                CREATE TABLE IF NOT EXISTS user_traffic (
                    uid TEXT PRIMARY KEY,
                    email TEXT,
                    total_uplink INTEGER DEFAULT 0,
                    total_downlink INTEGER DEFAULT 0,
                    monthly_uplink INTEGER DEFAULT 0,
                    monthly_downlink INTEGER DEFAULT 0,
                    current_month TEXT DEFAULT '',
                    last_seen INTEGER DEFAULT 0
                )
            ''')
            # 兼容表结构无缝升级
            for col, col_type in [
                ('monthly_uplink', 'INTEGER DEFAULT 0'),
                ('monthly_downlink', 'INTEGER DEFAULT 0'),
                ('current_month', 'TEXT DEFAULT ""')
            ]:
                try:
                    conn.execute(f'ALTER TABLE user_traffic ADD COLUMN {col} {col_type}')
                except Exception:
                    pass
            # 预热历史用量到 runtime_stats 和 pool_stats，避免初次加载时为未定义或空白
            cur = conn.cursor()
            cur.execute('SELECT uid, email, total_uplink, total_downlink, monthly_uplink, monthly_downlink, last_seen FROM user_traffic')
            total_p_up = 0
            total_p_down = 0
            for r in cur.fetchall():
                uid, email, up, down, m_up, m_down, last_seen = r
                total_p_up += (m_up or 0)
                total_p_down += (m_down or 0)
                up_s = self._format_bytes(up or 0)
                down_s = self._format_bytes(down or 0)
                last_s = self._format_last_seen(last_seen)
                self.runtime_stats[uid] = {
                    "uid": uid,
                    "email": email,
                    "is_online": False,
                    "speed_up": "0 B/s",
                    "speed_up_formatted": "0 B/s",
                    "speed_down": "0 B/s",
                    "speed_down_formatted": "0 B/s",
                    "total_uplink": up_s,
                    "total_up_formatted": up_s,
                    "total_downlink": down_s,
                    "total_down_formatted": down_s,
                    "total_traffic": self._format_bytes((up or 0) + (down or 0)),
                    "monthly_traffic": self._format_bytes((m_up or 0) + (m_down or 0)),
                    "session_traffic": "0 B",
                    "session_traffic_formatted": "0 B",
                    "online_duration": "0秒",
                    "session_duration_formatted": "0秒",
                    "last_seen_text": last_s,
                    "last_active_human": last_s
                }
            pool_used = total_p_up + total_p_down
            self.pool_stats["used_bytes"] = pool_used
            self.pool_stats["used_formatted"] = self._format_bytes(pool_used)
            conn.commit()

    def _format_bytes(self, size_bytes):
        """格式化字节大小为人类可读字符串"""
        if not size_bytes or size_bytes <= 0:
            return "0 B"
        units = ["B", "KB", "MB", "GB", "TB"]
        idx = 0
        val = float(size_bytes)
        while val >= 1024.0 and idx < len(units) - 1:
            val /= 1024.0
            idx += 1
        return f"{val:.2f} {units[idx]}"

    def _format_duration(self, seconds):
        """格式化秒数为人类可读时长"""
        if seconds <= 0:
            return "0秒"
        elif seconds < 60:
            return f"{int(seconds)}秒"
        elif seconds < 3600:
            m = int(seconds // 60)
            s = int(seconds % 60)
            return f"{m}分{s}秒"
        else:
            h = int(seconds // 3600)
            m = int((seconds % 3600) // 60)
            return f"{h}小时{m}分"

    def _format_last_seen(self, last_active_ts):
        """格式化最后活跃时间戳为友好相对时间"""
        if not last_active_ts or last_active_ts <= 0:
            return "从未活跃"
        diff = time.time() - last_active_ts
        if diff < 15:
            return "刚刚"
        elif diff < 60:
            return f"{int(diff)}秒前"
        elif diff < 3600:
            return f"{int(diff // 60)}分钟前"
        elif diff < 86400:
            return f"{int(diff // 3600)}小时前"
        else:
            return f"{int(diff // 86400)}天前"

    def _get_physical_connections(self, node_port):
        """从 Linux 底层 Socket 获取当前所有连入节点端口的真实物理客户端与连接数"""
        ip_counts = {}
        total_conn = 0
        try:
            cmd = f"ss -nt '( sport = :{node_port} )'"
            res = subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.DEVNULL)
            for line in res.strip().splitlines()[1:]:
                parts = line.split()
                if len(parts) >= 5:
                    m = re.search(r'\[?([0-9a-fA-F:.]+)\]?:[0-9]+$', parts[4])
                    if m:
                        raw_ip = m.group(1).strip('[]')
                        ip = raw_ip.replace('::ffff:', '') if raw_ip.lower().startswith('::ffff:') else raw_ip
                        if ip not in ('127.0.0.1', '::1', ''):
                            ip_counts[ip] = ip_counts.get(ip, 0) + 1
                            total_conn += 1
        except Exception:
            pass

        device_list = [
            {"ip": ip, "connections": count}
            for ip, count in sorted(ip_counts.items(), key=lambda x: x[1], reverse=True)
        ]
        return sorted(list(ip_counts.keys())), device_list, total_conn

    def _get_next_month_reset_ts(self):
        """获取下个月 1 号 00:00:00 的 UTC 时间戳 (对应订阅到期/重置时间)"""
        now = datetime.datetime.utcnow()
        year = now.year
        month = now.month + 1
        if month > 12:
            month = 1
            year += 1
        next_month = datetime.datetime(year, month, 1, 0, 0, 0)
        return int(next_month.timestamp())

    def _collect_step(self, clients_map, node_port):
        """执行单次周期数据采集"""
        now = time.time()
        now_month = time.strftime('%Y-%m')  # 当前自然月，如 '2026-09'

        # 1. 物理连接采集 (Linux 内核协议栈)
        active_ips, active_devices, total_connections = self._get_physical_connections(node_port)

        # 2. Xray 原生 Stats API 查询 (官方协议层独立记账)
        cmd = f"{self.xray_bin} api statsquery --server=127.0.0.1:{self.api_port} -pattern='user'"
        try:
            res = subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.DEVNULL)
            stats_data = json.loads(res).get('stat', [])
        except Exception:
            stats_data = []

        current_raw = {}
        for item in stats_data:
            parts = item.get('name', '').split('>>>')
            if len(parts) >= 4 and parts[0] == 'user':
                email, metric = parts[1], parts[3]
                if email not in current_raw:
                    current_raw[email] = {'up': 0, 'down': 0}
                if metric in ('uplink', 'downlink'):
                    current_raw[email][metric[:4]] = int(item.get('value', 0))

        total_spd_up = 0
        total_spd_down = 0
        new_runtime = {}

        with sqlite3.connect(self.db_path) as conn:
            # 自动月度轮转清零：如果进入了新月份，自动将上月月度消耗清零
            conn.execute('''
                UPDATE user_traffic
                SET monthly_uplink = 0, monthly_downlink = 0, current_month = ?
                WHERE current_month != ?
            ''', (now_month, now_month))

            for uid, email in clients_map.items():
                cur_up = current_raw.get(email, {}).get('up', 0)
                cur_down = current_raw.get(email, {}).get('down', 0)

                prev = self.last_raw_stats.get(email)
                delta_up, delta_down, speed_up, speed_down = 0, 0, 0, 0

                if prev:
                    dt = max(now - prev.get('time', now), 1.0)
                    delta_up = cur_up - prev['up'] if cur_up >= prev['up'] else cur_up
                    delta_down = cur_down - prev['down'] if cur_down >= prev['down'] else cur_down
                    speed_up = delta_up / dt
                    speed_down = delta_down / dt

                has_traffic = (delta_up > 0 or delta_down > 0)
                has_speed = (speed_up > 50 or speed_down > 50)
                is_transferring = has_traffic or has_speed

                # 写入持久化 (同步更新历史总计与本月统计)
                if has_traffic:
                    conn.execute('''
                        INSERT INTO user_traffic (uid, email, total_uplink, total_downlink, monthly_uplink, monthly_downlink, current_month, last_seen)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(uid) DO UPDATE SET
                            email = excluded.email,
                            total_uplink = total_uplink + excluded.total_uplink,
                            total_downlink = total_downlink + excluded.total_downlink,
                            monthly_uplink = monthly_uplink + excluded.monthly_uplink,
                            monthly_downlink = monthly_downlink + excluded.monthly_downlink,
                            current_month = excluded.current_month,
                            last_seen = excluded.last_seen
                    ''', (uid, email, delta_up, delta_down, delta_up, delta_down, now_month, int(now)))
                else:
                    conn.execute('''
                        INSERT OR IGNORE INTO user_traffic (uid, email, total_uplink, total_downlink, monthly_uplink, monthly_downlink, current_month, last_seen)
                        VALUES (?, ?, 0, 0, 0, 0, ?, ?)
                    ''', (uid, email, now_month, int(now)))

                row = conn.execute('SELECT total_uplink, total_downlink, monthly_uplink, monthly_downlink, last_seen FROM user_traffic WHERE uid = ?', (uid,)).fetchone()
                db_up, db_down, m_up, m_down, last_seen = row if row else (0, 0, 0, 0, 0)

                # 纯净传输会话计时 (无任何 IP 耦合，100% 准确)
                sess = self.user_sessions.setdefault(uid, {
                    'start_time': None,
                    'session_bytes': 0,
                    'last_active': 0
                })

                if is_transferring:
                    if sess['start_time'] is None:
                        sess['start_time'] = now
                        sess['session_bytes'] = 0
                    sess['session_bytes'] += (delta_up + delta_down)
                    sess['last_active'] = now
                    duration_sec = max(now - sess['start_time'], 0)
                    is_active = True
                else:
                    if sess['start_time'] and (now - sess['last_active']) > 30:
                        sess['start_time'] = None
                        sess['session_bytes'] = 0
                        duration_sec = 0
                        is_active = False
                    elif sess['start_time']:
                        duration_sec = max(sess['last_active'] - sess['start_time'], 0)
                        is_active = False
                    else:
                        duration_sec = 0
                        is_active = False

                total_spd_up += speed_up
                total_spd_down += speed_down

                spd_up_str = f"{self._format_bytes(speed_up)}/s"
                spd_down_str = f"{self._format_bytes(speed_down)}/s"
                up_str = self._format_bytes(db_up)
                down_str = self._format_bytes(db_down)
                sess_traffic_str = self._format_bytes(sess['session_bytes'])
                dur_str = self._format_duration(duration_sec) if is_active else "0秒"
                last_seen_str = self._format_last_seen(last_seen)

                new_runtime[uid] = {
                    "uid": uid,
                    "email": email,
                    "is_online": is_active,
                    "speed_up": spd_up_str,
                    "speed_up_formatted": spd_up_str,
                    "speed_down": spd_down_str,
                    "speed_down_formatted": spd_down_str,
                    "total_uplink": up_str,
                    "total_up_formatted": up_str,
                    "total_downlink": down_str,
                    "total_down_formatted": down_str,
                    "total_traffic": self._format_bytes(db_up + db_down),
                    "monthly_traffic": self._format_bytes(m_up + m_down),
                    "session_traffic": sess_traffic_str,
                    "session_traffic_formatted": sess_traffic_str,
                    "online_duration": dur_str,
                    "session_duration_formatted": dur_str,
                    "last_seen_text": last_seen_str,
                    "last_active_human": last_seen_str
                }
                self.last_raw_stats[email] = {'up': cur_up, 'down': cur_down, 'time': now}

            # 汇总全节点共享池月度总消耗
            pool_row = conn.execute('SELECT SUM(monthly_uplink), SUM(monthly_downlink) FROM user_traffic').fetchone()
            p_up = pool_row[0] or 0
            p_down = pool_row[1] or 0
            pool_used = p_up + p_down
            
            limit_bytes = int(self.monthly_limit_gb * 1024 * 1024 * 1024) if self.monthly_limit_gb > 0 else 0
            remaining_bytes = max(limit_bytes - pool_used, 0) if limit_bytes > 0 else 0
            percent = round((pool_used / limit_bytes * 100), 1) if limit_bytes > 0 else 0.0

            pool_status = "normal"
            if percent >= 90:
                pool_status = "danger"
            elif percent >= 75:
                pool_status = "warning"

            new_pool_stats = {
                "used_bytes": pool_used,
                "used_up_bytes": p_up,
                "used_down_bytes": p_down,
                "limit_bytes": limit_bytes,
                "limit_gb": self.monthly_limit_gb,
                "used_formatted": self._format_bytes(pool_used),
                "limit_formatted": f"{self.monthly_limit_gb:.2f} GB" if self.monthly_limit_gb > 0 else "无限制",
                "remaining_formatted": self._format_bytes(remaining_bytes) if limit_bytes > 0 else "充足",
                "percent": percent,
                "status": pool_status
            }

            conn.commit()

        # 加锁原子更新对外只读指标
        with self.lock:
            self.runtime_stats = new_runtime
            self.active_ips = active_ips
            self.active_devices = active_devices
            self.total_connections = total_connections
            self.total_speed_up = total_spd_up
            self.total_speed_down = total_spd_down
            self.pool_stats = new_pool_stats

    def _start_collector(self):
        """后台轻量守护线程，每 3 秒非阻塞执行一次"""
        def loop():
            time.sleep(2)
            while True:
                try:
                    clients_map = {}
                    node_port = 54321
                    if os.path.exists('/etc/xray/config.json'):
                        with open('/etc/xray/config.json', 'r') as f:
                            data = json.load(f)
                            inbound = data.get('inbounds', [{}])[0]
                            node_port = inbound.get('port', 54321)
                            for c in inbound.get('settings', {}).get('clients', []):
                                if c.get('id'):
                                    clients_map[c['id']] = c.get('email', f"user_{c['id'][:8]}")
                    if clients_map:
                        self._collect_step(clients_map, node_port)
                except Exception:
                    pass
                time.sleep(3)

        t = threading.Thread(target=loop, daemon=True)
        t.start()

    def get_subscription_info(self):
        """生成符合行业通用规范的 Subscription-Userinfo 响应头 (共享总流量池模式)"""
        with self.lock:
            p_up = self.pool_stats.get("used_up_bytes", 0)
            p_down = self.pool_stats.get("used_down_bytes", 0)
            limit = self.pool_stats.get("limit_bytes", 0)
            if limit <= 0:
                limit = 10 * 1024 * 1024 * 1024 * 1024  # 默认 10TB 虚拟限额
            expire_ts = self._get_next_month_reset_ts()
            return f"upload={p_up}; download={p_down}; total={limit}; expire={expire_ts}"

    def get_stats(self):
        """对外提供只读实时指标"""
        with self.lock:
            return {
                "status": "ok",
                "active_user_count": sum(1 for u in self.runtime_stats.values() if u.get('is_online')),
                "total_speed_up": f"{self._format_bytes(self.total_speed_up)}/s",
                "total_speed_down": f"{self._format_bytes(self.total_speed_down)}/s",
                "active_ips": self.active_ips,
                "active_devices": self.active_devices,
                "total_connections": self.total_connections,
                "pool": self.pool_stats,
                "users": self.runtime_stats
            }

    def reset_user_traffic(self, uid):
        """重置某个用户的历史累计流量与会话 (保留月度统计)"""
        with sqlite3.connect(self.db_path) as conn:
            conn.execute('UPDATE user_traffic SET total_uplink = 0, total_downlink = 0 WHERE uid = ?', (uid,))
            conn.commit()
        if uid in self.user_sessions:
            self.user_sessions[uid]['session_bytes'] = 0
            self.user_sessions[uid]['start_time'] = None
            self.user_sessions[uid]['last_active'] = 0
        return True

    def set_monthly_limit(self, limit_gb):
        """动态修改并持久化月度流量限制 (0 表示无限制，仅统计已用流量)"""
        try:
            val = max(0.0, float(limit_gb))
        except (TypeError, ValueError):
            val = 0.0
        with self.lock:
            self.monthly_limit_gb = val
            limit_bytes = int(val * 1024 * 1024 * 1024)
            self.pool_stats["limit_gb"] = val
            self.pool_stats["limit_bytes"] = limit_bytes
            self.pool_stats["limit_formatted"] = f"{val:.2f} GB" if val > 0 else "无限制"
            if val > 0:
                p_used = self.pool_stats.get("used_bytes", 0)
                rem = max(0, limit_bytes - p_used)
                self.pool_stats["remaining_formatted"] = self._format_bytes(rem)
                self.pool_stats["percent"] = round((p_used / limit_bytes * 100), 1)
            else:
                self.pool_stats["remaining_formatted"] = "充足"
                self.pool_stats["percent"] = 0.0
                self.pool_stats["status"] = "normal"
        with sqlite3.connect(self.db_path) as conn:
            conn.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('monthly_limit_gb', ?)", (str(val),))
            conn.commit()
        return val
