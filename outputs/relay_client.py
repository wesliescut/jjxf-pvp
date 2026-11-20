"""HTTPS client for the two-player lobby relay (no gameplay transport yet)."""
from __future__ import annotations

import json
import socket
import urllib.error
import urllib.request
from urllib.parse import urlparse

ERRORS = {
    "room_expired": "房间不存在或房主已离开",
    "room_full": "房间已有一位客人",
    "config_mismatch": "游戏本体或两个 ZIP 的配置与房主不一致",
    "invalid_code": "房间码格式错误",
    "unauthorized": "房间凭据失效",
}


def call(base_url: str, action: str, payload: dict) -> dict:
    base = base_url.strip().rstrip("/")
    parsed = urlparse(base)
    if parsed.scheme != "https" and not (parsed.scheme == "http" and parsed.hostname in ("127.0.0.1", "localhost")):
        raise ValueError("中继地址须以 https:// 开头")
    if action not in ("create", "join", "status", "leave"):
        raise ValueError("无效操作")
    data = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    request = urllib.request.Request(base + "/" + action, data=data,
                                     headers={"Content-Type": "application/json", "Accept": "application/json",
                                              "User-Agent": "JJXF-Room/1.0"}, method="POST")
    status = 200
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            status = response.status
            raw = response.read(16_385)
    except urllib.error.HTTPError as error:
        status = error.code
        raw = error.read(16_385)
    except (urllib.error.URLError, TimeoutError, socket.timeout) as error:
        raise ValueError("连接房间服务超时或失败。请在这台电脑的浏览器中打开中继地址检查网络：" + base) from error
    if len(raw) > 16_384:
        raise ValueError("中继响应过大")
    try:
        result = json.loads(raw)
    except (ValueError, UnicodeDecodeError) as error:
        raise ValueError(f"中继未返回房间数据（HTTP {status}）；可能被网络或服务商拦截") from error
    if not isinstance(result, dict):
        raise ValueError("中继响应格式错误")
    if result.get("error"):
        raise ValueError(ERRORS.get(result["error"], str(result["error"])))
    return result


def probe(base_url: str) -> None:
    base = base_url.strip().rstrip("/")
    request = urllib.request.Request(base + "/", headers={"User-Agent": "JJXF-Room/1.0",
                                                       "Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            raw = response.read(1024)
    except urllib.error.HTTPError as error:
        raw = error.read(1024)
    except (urllib.error.URLError, TimeoutError, socket.timeout) as error:
        raise ValueError("这台电脑暂时无法访问跨网房间服务；请检查校园网是否能打开：" + base) from error
    try:
        data = json.loads(raw)
    except ValueError as error:
        raise ValueError("房间服务返回了非预期页面，可能被网络拦截") from error
    if data != {"error": "method_not_allowed"}:
        raise ValueError("房间服务返回了非预期结果")
