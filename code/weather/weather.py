import requests
import json
import time
import schedule
from datetime import datetime, timedelta, timezone
from typing import Dict, Optional
import os
import threading

# === НАСТРОЙКИ ===
CITY_NAME = "Test"
LATITUDE = 00.0000
LONGITUDE = 00.0000
TIMEZONE_OFFSET = 0  # Часовой пояс +3 (Москва)
BASE_URL = "https://api.open-meteo.com/v1/forecast"

# Файл для логирования
LOG_FILE = "weather_data.log"

# Глобальная блокировка для безопасной записи в файл
file_lock = threading.Lock()

# === ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ===
def log_to_file(data: str, request_type: str):
    """Запись данных в файл лога с блокировкой"""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    log_entry = f"{timestamp} | {request_type} | {data}\n"

    with file_lock:
        try:
            with open(LOG_FILE, 'a', encoding='utf-8') as f:
                f.write(log_entry)
        except Exception as e:
            print(json.dumps({"error": f"Ошибка записи в файл: {e}"}))

def make_request(url: str, params: Dict, request_type: str) -> Optional[Dict]:
    """Выполнение запроса с одной повторной попыткой"""
    for attempt in range(2):  # 0 = первая попытка, 1 = повторная
        try:
            response = requests.get(url, params=params, timeout=10)

            if response.status_code == 200:
                data = response.json()

                # Логируем сырые данные
                log_to_file(json.dumps(data, ensure_ascii=False), request_type)

                return data
            else:
                error_msg = f"ERROR:{response.status_code}"
                log_to_file(error_msg, request_type)
                error_json = {
                    "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                    "type": request_type,
                    "error": f"HTTP {response.status_code}"
                }
                print(json.dumps(error_json))

                if attempt == 0:  # Только одна повторная попытка
                    time.sleep(30)

        except requests.exceptions.Timeout:
            error_msg = "ERROR:TIMEOUT"
            log_to_file(error_msg, request_type)
            error_json = {
                "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                "type": request_type,
                "error": "Timeout"
            }
            print(json.dumps(error_json))
            if attempt == 0:
                time.sleep(30)

        except Exception as e:
            error_msg = f"ERROR:{str(e)[:50]}"
            log_to_file(error_msg, request_type)
            error_json = {
                "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                "type": request_type,
                "error": str(e)
            }
            print(json.dumps(error_json))
            if attempt == 0:
                time.sleep(30)

    return None

# === ФУНКЦИИ ЗАПРОСОВ ===
def fetch_current_weather():
    """Запрос текущей погоды"""
    params = {
        'latitude': LATITUDE,
        'longitude': LONGITUDE,
        'current_weather': 'true',
        'windspeed_unit': 'ms',
        'timezone': 'auto'
    }

    data = make_request(BASE_URL, params, "CURRENT")

    if data and 'current_weather' in data:
        current = data['current_weather']

        # Формируем JSON для вывода
        output_json = {
            "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "type": "CURRENT",
            "city": CITY_NAME,
            "data": current
        }
        print(json.dumps(output_json, ensure_ascii=False))
    else:
        error_json = {
            "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "type": "CURRENT",
            "city": CITY_NAME,
            "error": "No data received"
        }
        print(json.dumps(error_json))

def fetch_hourly_forecast():
    """Запрос почасового прогноза"""
    params = {
        'latitude': LATITUDE,
        'longitude': LONGITUDE,
        'hourly': 'temperature_2m,precipitation,weathercode',
        'forecast_days': 2,
        'windspeed_unit': 'ms',
        'timezone': 'auto'
    }

    data = make_request(BASE_URL, params, "HOURLY")

    if data and 'hourly' in data:
        hourly = data['hourly']

        # Формируем JSON для вывода
        output_json = {
            "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "type": "HOURLY",
            "city": CITY_NAME,
            "data": {
                "time": hourly['time'],
                "temperature_2m": hourly['temperature_2m'],
                "precipitation": hourly.get('precipitation', []),
                "weathercode": hourly.get('weathercode', [])
            }
        }
        print(json.dumps(output_json, ensure_ascii=False))
    else:
        error_json = {
            "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "type": "HOURLY",
            "city": CITY_NAME,
            "error": "No data received"
        }
        print(json.dumps(error_json))

def fetch_daily_forecast():
    """Запрос недельного прогноза"""
    params = {
        'latitude': LATITUDE,
        'longitude': LONGITUDE,
        'daily': 'temperature_2m_max,temperature_2m_min,precipitation_sum,weathercode',
        'forecast_days': 7,
        'windspeed_unit': 'ms',
        'timezone': 'auto'
    }

    data = make_request(BASE_URL, params, "DAILY")

    if data and 'daily' in data:
        daily = data['daily']

        # Формируем JSON для вывода
        output_json = {
            "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "type": "DAILY",
            "city": CITY_NAME,
            "data": daily
        }
        print(json.dumps(output_json, ensure_ascii=False))
    else:
        error_json = {
            "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "type": "DAILY",
            "city": CITY_NAME,
            "error": "No data received"
        }
        print(json.dumps(error_json))

def setup_schedule():
    """Настройка точного расписания выполнения запросов"""

    # CURRENT: в 15, 30, 45, 00 минут каждого часа
    schedule.every().hour.at(":00").do(fetch_current_weather)
    schedule.every().hour.at(":15").do(fetch_current_weather)
    schedule.every().hour.at(":30").do(fetch_current_weather)
    schedule.every().hour.at(":45").do(fetch_current_weather)

    # HOURLY: в 04 и в 34 минуту каждого часа
    schedule.every().hour.at(":04").do(fetch_hourly_forecast)
    schedule.every().hour.at(":34").do(fetch_hourly_forecast)

    # DAILY: в указанные часы в 07 минуту
    daily_times = ["00:07", "02:07", "04:07", "06:07", "08:07", "10:07",
                   "12:07", "14:07", "16:07", "18:07", "20:07", "22:07"]

    for time_str in daily_times:
        schedule.every().day.at(time_str).do(fetch_daily_forecast)

# === ОСНОВНАЯ ЧАСТЬ ===
if __name__ == "__main__":
    # Очищаем файл лога при запуске (опционально)
    if os.path.exists(LOG_FILE):
        try:
            # Архивируем старый лог вместо удаления
            archive_name = f"weather_data_{datetime.now().strftime('%Y%m%d_%H%M%S')}.log"
            os.rename(LOG_FILE, archive_name)
        except:
            pass

    # Выводим информацию о запуске (только один раз при старте)
    startup_info = {
        "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "status": "startup",
        "city": CITY_NAME,
        "latitude": LATITUDE,
        "longitude": LONGITUDE,
        "timezone_offset": TIMEZONE_OFFSET,
        "schedule": {
            "CURRENT": ["00", "15", "30", "45"],
            "HOURLY": ["04", "34"],
            "DAILY": ["00:07", "02:07", "04:07", "06:07", "08:07", "10:07",
                     "12:07", "14:07", "16:07", "18:07", "20:37", "22:07"]
        }
    }
    print(json.dumps(startup_info, ensure_ascii=False))

    # Настраиваем расписание
    setup_schedule()

    # Выполняем все запросы сразу при старте
    fetch_current_weather()
    time.sleep(2)
    fetch_hourly_forecast()
    time.sleep(2)
    fetch_daily_forecast()

    # Основной цикл выполнения по расписанию
    try:
        while True:
            schedule.run_pending()
            time.sleep(1)  # Проверяем расписание каждую секунду

    except KeyboardInterrupt:
        shutdown_info = {
            "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "status": "shutdown",
            "message": "System stopped by user"
        }
        print(json.dumps(shutdown_info))
