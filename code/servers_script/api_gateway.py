#!/usr/bin/env python3
"""
API-gateway + Collector для системы мониторинга.
Принимает метрики от серверов, погоды и датчиков.
Записывает данные в PostgreSQL + TimescaleDB.
"""

import json
import logging
import os
import sys
import threading
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from urllib.parse import urlparse
from typing import Optional

import psycopg
from psycopg.rows import dict_row

# =============================================
# Загрузка конфигурации
# =============================================

def _load_config() -> dict:
    """Загрузка настроек из api_gateway.conf"""
    config = {}
    script_dir = os.path.dirname(os.path.abspath(__file__))
    conf_path = os.path.join(script_dir, "api_gateway.conf")

    if os.path.exists(conf_path):
        try:
            with open(conf_path, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    if "=" in line:
                        key, val = line.split("=", 1)
                        config[key.strip()] = val.strip()
        except Exception as e:
            print(f"WARNING: Ошибка чтения конфига {conf_path}: {e}")
    else:
        print(f"WARNING: Файл конфига не найден: {conf_path}")

    return config

_cfg = _load_config()

# =============================================
# Конфигурация
# =============================================
DB_HOST = os.getenv("DB_HOST", _cfg.get("DB_HOST", "localhost"))
DB_PORT = int(os.getenv("DB_PORT", _cfg.get("DB_PORT", "5432")))
DB_NAME = os.getenv("DB_NAME", _cfg.get("DB_NAME", "monitoring"))
DB_USER = os.getenv("DB_USER", _cfg.get("DB_USER", "monitoring"))
DB_PASS = os.getenv("DB_PASS", _cfg.get("DB_PASS", "monitoring"))

LISTEN_HOST = os.getenv("LISTEN_HOST", _cfg.get("LISTEN_HOST", "0.0.0.0"))
LISTEN_PORT = int(os.getenv("LISTEN_PORT", _cfg.get("LISTEN_PORT", "1234")))

LOG_LEVEL = os.getenv("LOG_LEVEL", _cfg.get("LOG_LEVEL", "INFO"))

# --- Маппинги серверов ---
def _parse_id_map(raw: str) -> dict:
    result = {}
    if not raw:
        return result
    for pair in raw.split(","):
        pair = pair.strip()
        if ":" in pair:
            k, v = pair.split(":", 1)
            try:
                result[k.strip()] = int(v.strip())
            except ValueError:
                result[k.strip()] = v.strip()
    return result

SERVER_ID_MAP = _parse_id_map(_cfg.get("SERVER_ID_MAP", ""))
HOSTNAME_ID_MAP = _parse_id_map(_cfg.get("HOSTNAME_ID_MAP", ""))
DEFAULT_SERVER_ID = int(_cfg.get("DEFAULT_SERVER_ID", "99"))

# =============================================
# Логирование
# =============================================
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL),
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger(__name__)

# =============================================
# Подключение к БД
# =============================================
_local = threading.local()

def get_db() -> psycopg.Connection:
    conn = getattr(_local, "conn", None)
    if conn is None or conn.closed:
        conn = psycopg.connect(
            host=DB_HOST,
            port=DB_PORT,
            dbname=DB_NAME,
            user=DB_USER,
            password=DB_PASS,
            row_factory=dict_row,
        )
        _local.conn = conn
        log.debug(f"Поток {threading.current_thread().name}: подключение к БД")
    return conn

def close_db():
    conn = getattr(_local, "conn", None)
    if conn and not conn.closed:
        conn.close()
        _local.conn = None

# =============================================
# Утилиты
# =============================================

def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()

def _safe_float(val) -> Optional[float]:
    if val is None or val in ("N/D", ""):
        return None
    try:
        return float(val)
    except (ValueError, TypeError):
        return None

def _safe_str(val) -> Optional[str]:
    if val is None or val == "N/D":
        return None
    return str(val)

# =============================================
# Store функции (полностью оригинальные)
# =============================================

def store_server_metrics(data: dict) -> bool:
    db = get_db()
    try:
        ip = data.get("ip_server", "")
        hostname = data.get("system", {}).get("hostname", "")

        server_id = SERVER_ID_MAP.get(ip)
        if server_id is None:
            server_id = HOSTNAME_ID_MAP.get(hostname, DEFAULT_SERVER_ID)

        server_type = data.get("system", {}).get("type", "unknown")
        if "zfs_pools" in data:
            server_type = server_type or "xigmanas"
        if "version" in data.get("system", {}):
            server_type = server_type or "vyos"

        cpu = data.get("cpu", {})
        mem = data.get("memory", {})
        net = data.get("network", {})

        zfs_pools = json.dumps(data.get("zfs_pools", []))
        disks = json.dumps(data.get("disks", []))

        pool_health = None
        pools = data.get("zfs_pools", [])
        if pools:
            pool_health = pools[0].get("health") == "ONLINE"

        query = """
            INSERT INTO server_metrics (
                time, server_id, ip_server, hostname, uptime, server_type,
                cpu_model, cpu_freq_nominal, cpu_freq_real, cpu_cores,
                cpu_temp, cpu_load_avg,
                ram_total, ram_used, ram_free, ram_available,
                net_interface, net_rx_mbps, net_tx_mbps,
                zfs_pools, disks,
                vyos_version, disk_total_gb, disk_used_gb, disk_free_gb,
                net_total_rx_gb, net_total_tx_gb,
                pool_health, fan_health
            ) VALUES (
                NOW(), %s, %s, %s, %s, %s,
                %s, %s, %s, %s,
                %s, %s,
                %s, %s, %s, %s,
                %s, %s, %s,
                %s, %s,
                %s, %s, %s, %s,
                %s, %s,
                %s, %s
            )
        """
        with db.cursor() as cur:
            cur.execute(query, (
                server_id, ip, hostname,
                data.get("system", {}).get("uptime"),
                server_type,
                cpu.get("model"),
                _safe_float(cpu.get("frequency_nominal_mhz")),
                _safe_str(cpu.get("frequency_real_mhz")),
                cpu.get("cores"),
                _safe_float(cpu.get("temperature_c")),
                _safe_float(cpu.get("load_avg")),
                _safe_float(mem.get("total_gb")),
                _safe_float(mem.get("used_gb")),
                _safe_float(mem.get("free_gb")),
                _safe_float(mem.get("available_gb")),
                net.get("interface"),
                _safe_float(net.get("rx_mbps")),
                _safe_float(net.get("tx_mbps")),
                zfs_pools,
                disks,
                data.get("system", {}).get("version"),
                _safe_float(data.get("disk", {}).get("total_gb")),
                _safe_float(data.get("disk", {}).get("used_gb")),
                _safe_float(data.get("disk", {}).get("free_gb")),
                _safe_float(net.get("total_rx_gb")),
                _safe_float(net.get("total_tx_gb")),
                pool_health,
                None,
            ))
        db.commit()
        log.info(f"server_metrics: server_id={server_id} hostname={hostname}")
        return True
    except Exception as e:
        log.error(f"Ошибка записи server_metrics: {e}", exc_info=True)
        db.rollback()
        return False


def store_vm_metrics(data: list) -> bool:
    db = get_db()
    try:
        query = """
            INSERT INTO vm_metrics (
                time, vm_id, vm_type, vm_name, vm_status,
                cpu_usage, memory_used, memory_allocated
            ) VALUES (NOW(), %s, %s, %s, %s, %s, %s, %s)
        """
        rows = []
        for vm in data:
            rows.append((
                str(vm.get("id", "")),
                vm.get("type", "vm"),
                vm.get("name", "Unknown"),
                vm.get("status") == "running",
                _safe_float(vm.get("cpu_usage")),
                _safe_float(vm.get("memory_used")),
                _safe_float(vm.get("memory_allocated")),
            ))
        with db.cursor() as cur:
            cur.executemany(query, rows)
        db.commit()
        log.info(f"vm_metrics: записано {len(rows)} записей")
        return True
    except Exception as e:
        log.error(f"Ошибка записи vm_metrics: {e}", exc_info=True)
        db.rollback()
        return False


def store_weather_metrics(data: dict) -> bool:
    db = get_db()
    try:
        weather_type = data.get("type", "current")
        city = data.get("city", "")
        payload = json.dumps(data.get("data", data))

        query = """
            INSERT INTO weather_metrics (time, weather_type, city, data)
            VALUES (NOW(), %s, %s, %s)
        """
        with db.cursor() as cur:
            cur.execute(query, (weather_type, city, payload))
        db.commit()
        log.info(f"weather_metrics: type={weather_type} city={city}")
        return True
    except Exception as e:
        log.error(f"Ошибка записи weather_metrics: {e}", exc_info=True)
        db.rollback()
        return False


def store_room_metrics(data: dict) -> bool:
    db = get_db()
    try:
        query = """
            INSERT INTO room_metrics (
                time, sensor_id,
                temperature_top, temperature_down,
                humidity_top, humidity_down,
                voltage, current, power, energy,
                sum_power, sum_energy
            ) VALUES (
                NOW(), %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s
            )
        """
        with db.cursor() as cur:
            cur.execute(query, (
                data.get("sensor_id"),
                _safe_float(data.get("temperature_top")),
                _safe_float(data.get("temperature_down")),
                _safe_float(data.get("humidity_top")),
                _safe_float(data.get("humidity_down")),
                _safe_float(data.get("voltage")),
                _safe_float(data.get("current")),
                _safe_float(data.get("power")),
                _safe_float(data.get("energy")),
                _safe_float(data.get("sum_power")),
                _safe_float(data.get("sum_energy")),
            ))
        db.commit()
        log.info(f"room_metrics: sensor={data.get('sensor_id')}")
        return True
    except Exception as e:
        log.error(f"Ошибка записи room_metrics: {e}", exc_info=True)
        db.rollback()
        return False


# =============================================
# HTTP Handler
# =============================================

class MonitorHandler(BaseHTTPRequestHandler):

    def log_message(self, format, *args):
        log.debug(f"{self.client_address[0]} - {format % args}")

    def _send_response(self, code: int, body: dict):
        """Надёжная отправка JSON с обработкой datetime и других типов."""
        try:
            def json_default(obj):
                if isinstance(obj, datetime):
                    return obj.isoformat()
                if isinstance(obj, (datetime.date, datetime.timedelta)):
                    return str(obj)
                if hasattr(obj, '__float__'):
                    try:
                        return float(obj)
                    except (TypeError, ValueError):
                        pass
                return str(obj)

            json_str = json.dumps(body, ensure_ascii=False, default=json_default)

            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json_str.encode("utf-8"))
            self.wfile.flush()

        except Exception as e:
            log.error(f"КРИТИЧЕСКАЯ ошибка в _send_response: {e}", exc_info=True)
            try:
                self.send_response(500)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"error": str(e)}, ensure_ascii=False).encode("utf-8"))
            except:
                pass

    def do_GET(self):
        try:
            parsed = urlparse(self.path)
            path = parsed.path

            if path == "/health":
                self._send_response(200, {"status": "ok", "time": _now_iso()})
                return

            if path == "/api/v1/last/server":
                self._get_last_server_metrics()
                return
            if path == "/api/v1/last/vm":
                self._get_last_vm_metrics()
                return
            if path == "/api/v1/last/weather":
                self._get_last_weather()
                return

            self._send_response(404, {"error": "Not found"})
        except Exception as e:
            log.error(f"Ошибка в do_GET: {e}", exc_info=True)
            try:
                self._send_response(500, {"error": "Internal server error"})
            except:
                pass

    def do_POST(self):
        try:
            parsed = urlparse(self.path)
            path = parsed.path

            content_length = int(self.headers.get("Content-Length", 0))
            if content_length == 0:
                self._send_response(400, {"error": "Empty body"})
                return

            body = json.loads(self.rfile.read(content_length))

            if path == "/api/v1/metrics/server":
                self._handle_server_metrics(body)
            elif path == "/api/v1/metrics/vm":
                self._handle_vm_metrics(body)
            elif path == "/api/v1/metrics/weather":
                self._handle_weather_metrics(body)
            elif path == "/api/v1/metrics/room":
                self._handle_room_metrics(body)
            else:
                self._send_response(404, {"error": "Unknown endpoint"})
        except json.JSONDecodeError as e:
            self._send_response(400, {"error": f"Invalid JSON: {e}"})
        except Exception as e:
            log.error(f"Ошибка в do_POST: {e}", exc_info=True)
            try:
                self._send_response(500, {"error": "Internal error"})
            except:
                pass

    # POST handlers
    def _handle_server_metrics(self, body):
        if isinstance(body, list):
            results = [store_server_metrics(item) for item in body]
            ok = sum(results)
            self._send_response(200, {"stored": ok, "total": len(results)})
        else:
            ok = store_server_metrics(body)
            self._send_response(200 if ok else 500, {"stored": 1 if ok else 0})

    def _handle_vm_metrics(self, body):
        data = body if isinstance(body, list) else [body]
        ok = store_vm_metrics(data)
        self._send_response(200 if ok else 500, {"stored": len(data) if ok else 0})

    def _handle_weather_metrics(self, body):
        data = body if isinstance(body, list) else [body]
        results = [store_weather_metrics(item) for item in data]
        ok = sum(results)
        self._send_response(200 if ok else 500, {"stored": ok, "total": len(results)})

    def _handle_room_metrics(self, body):
        data = body if isinstance(body, list) else [body]
        results = [store_room_metrics(item) for item in data]
        ok = sum(results)
        self._send_response(200 if ok else 500, {"stored": ok, "total": len(results)})

    # GET handlers — исправленные
    def _get_last_server_metrics(self):
        db = get_db()
        try:
            query = """
                SELECT DISTINCT ON (server_id)
                    server_id, ip_server, hostname, uptime, server_type,
                    cpu_model, cpu_freq_nominal, cpu_freq_real, cpu_cores,
                    cpu_temp, cpu_load_avg,
                    ram_total, ram_used, ram_free, ram_available,
                    net_interface, net_rx_mbps, net_tx_mbps,
                    zfs_pools, disks,
                    vyos_version, disk_total_gb, disk_used_gb, disk_free_gb,
                    net_total_rx_gb, net_total_tx_gb,
                    pool_health, fan_health, time
                FROM server_metrics
                ORDER BY server_id, time DESC
            """
            with db.cursor() as cur:
                cur.execute(query)
                rows = cur.fetchall()

            result = []
            for row in rows:
                d = dict(row)
                for field in ("zfs_pools", "disks"):
                    if d.get(field):
                        try:
                            d[field] = json.loads(d[field])
                        except (TypeError, json.JSONDecodeError):
                            d[field] = None

                if d.get('time') and hasattr(d['time'], 'isoformat'):
                    d['time'] = d['time'].isoformat()

                result.append(d)

            self._send_response(200, {"servers": result})
        except Exception as e:
            log.error(f"Ошибка чтения server_metrics: {e}", exc_info=True)
            self._send_response(500, {"error": str(e)})

    def _get_last_vm_metrics(self):
        db = get_db()
        try:
            query = """
                SELECT DISTINCT ON (vm_id)
                    vm_id, vm_type, vm_name, vm_status,
                    cpu_usage, memory_used, memory_allocated, time
                FROM vm_metrics
                ORDER BY vm_id, time DESC
            """
            with db.cursor() as cur:
                cur.execute(query)
                rows = cur.fetchall()

            result = []
            for row in rows:
                d = dict(row)
                if d.get('time') and hasattr(d['time'], 'isoformat'):
                    d['time'] = d['time'].isoformat()
                result.append(d)

            self._send_response(200, {"vms": result})
        except Exception as e:
            log.error(f"Ошибка чтения vm_metrics: {e}", exc_info=True)
            self._send_response(500, {"error": str(e)})

    def _get_last_weather(self):
        db = get_db()
        try:
            query = """
                SELECT DISTINCT ON (weather_type)
                    weather_type, city, data, time
                FROM weather_metrics
                ORDER BY weather_type, time DESC
            """
            with db.cursor() as cur:
                cur.execute(query)
                rows = cur.fetchall()

            result = {}
            for row in rows:
                d = dict(row)
                if d.get('time') and hasattr(d['time'], 'isoformat'):
                    d['time'] = d['time'].isoformat()

                if d.get("data"):
                    try:
                        d["data"] = json.loads(d["data"])
                    except (TypeError, json.JSONDecodeError):
                        pass

                weather_type = d.pop("weather_type", "unknown")
                result[weather_type] = d

            self._send_response(200, result)
        except Exception as e:
            log.error(f"Ошибка чтения weather_metrics: {e}", exc_info=True)
            self._send_response(500, {"error": str(e)})


# =============================================
# Запуск сервера
# =============================================

class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    log.info(f"Запуск API-gateway на {LISTEN_HOST}:{LISTEN_PORT}")
    log.info(f"БД: {DB_HOST}:{DB_PORT}/{DB_NAME}")

    try:
        get_db()
        close_db()
    except Exception as e:
        log.error(f"Не удалось подключиться к БД: {e}", exc_info=True)
        sys.exit(1)

    server = ThreadedHTTPServer((LISTEN_HOST, LISTEN_PORT), MonitorHandler)
    log.info(f"API-gateway запущен http://{LISTEN_HOST}:{LISTEN_PORT}")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Остановка API-gateway...")
        server.shutdown()
    except Exception as e:
        log.error(f"Неожиданная ошибка сервера: {e}", exc_info=True)


if __name__ == "__main__":
    main()
