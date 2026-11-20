"""Deploy the room relay to Cloudflare through the REST API.

The point is to avoid asking players to install Node and run wrangler in a
terminal: they paste a Cloudflare API token in the launcher, press one button,
and get a ready workers.dev address.
"""
from __future__ import annotations

import json
import secrets
import urllib.error
import urllib.request

import relay_bundle

API = "https://api.cloudflare.com/client/v4"


class DeployError(Exception):
    """Raised with the Cloudflare response body so the dialog can show it."""


def _request(token: str, method: str, path: str, body=None, content_type: str = "application/json"):
    headers = {"Authorization": "Bearer " + token}
    data = None
    if body is not None:
        if isinstance(body, bytes):
            data = body
        else:
            data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = content_type
    request = urllib.request.Request(API + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            raw = response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", "replace")
        raise DeployError("HTTP %d: %s" % (error.code, detail[:800])) from error
    except urllib.error.URLError as error:
        raise DeployError("无法连接 Cloudflare API：%s" % error.reason) from error
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except json.JSONDecodeError as error:
        raise DeployError("Cloudflare 返回了无法解析的内容：%s" % raw[:300]) from error


def _result(response, what: str):
    if not isinstance(response, dict) or not response.get("success", False):
        errors = response.get("errors") if isinstance(response, dict) else response
        raise DeployError("%s失败：%s" % (what, json.dumps(errors, ensure_ascii=False)[:600]))
    return response.get("result")


def verify_token(token: str) -> dict:
    token = token.strip()
    if not token:
        raise DeployError("请先粘贴 API Token")
    result = _result(_request(token, "GET", "/user/tokens/verify"), "校验 Token")
    if str(result.get("status", "")).lower() != "active":
        raise DeployError("Token 状态是 %s，不是 active" % result.get("status"))
    return result


def list_accounts(token: str) -> list[dict]:
    result = _result(_request(token, "GET", "/accounts"), "读取账号列表")
    accounts = [item for item in (result or []) if isinstance(item, dict)]
    if not accounts:
        raise DeployError("这个 Token 下没有任何账号，请确认 Token 属于你的主账号")
    return accounts


def _multipart(fields: dict[str, tuple[str, bytes, str]]) -> tuple[bytes, str]:
    boundary = "----jjxf" + secrets.token_hex(12)
    chunks: list[bytes] = []
    for name, (filename, payload, content_type) in fields.items():
        chunks.append(("--%s\r\n" % boundary).encode())
        chunks.append(('Content-Disposition: form-data; name="%s"; filename="%s"\r\n'
                       % (name, filename)).encode())
        chunks.append(("Content-Type: %s\r\n\r\n" % content_type).encode())
        chunks.append(payload)
        chunks.append(b"\r\n")
    chunks.append(("--%s--\r\n" % boundary).encode())
    return b"".join(chunks), "multipart/form-data; boundary=" + boundary


def _worker_metadata(with_migrations: bool) -> dict:
    metadata = {
        "main_module": "index.js",
        "compatibility_date": relay_bundle.COMPATIBILITY_DATE,
        "bindings": [{
            "type": "durable_object_namespace",
            "name": relay_bundle.DO_BINDING,
            "class_name": relay_bundle.DO_CLASS,
        }],
    }
    if with_migrations:
        metadata["migrations"] = {"new_tag": "v1", "new_sqlite_classes": [relay_bundle.DO_CLASS]}
    return metadata


def _upload(token: str, account_id: str, script_name: str, with_migrations: bool) -> None:
    body, content_type = _multipart({
        "metadata": ("metadata.json",
                     json.dumps(_worker_metadata(with_migrations)).encode("utf-8"),
                     "application/json"),
        "index.js": ("index.js", relay_bundle.WORKER_JS.encode("utf-8"),
                     "application/javascript+module"),
    })
    _result(_request(token, "PUT", "/accounts/%s/workers/scripts/%s" % (account_id, script_name),
                     body=body, content_type=content_type), "上传中继脚本")


def deploy_worker(token: str, account_id: str, script_name: str, progress=print) -> None:
    """Upload the relay. A brand new Worker needs the v1 migration; an existing one
    already carries that tag and rejects it (error 10079), so retry without it."""
    progress("上传中继脚本 %s …" % script_name)
    try:
        _upload(token, account_id, script_name, with_migrations=True)
        return
    except DeployError as error:
        text = str(error)
        if "10079" not in text and "migration tag" not in text.lower():
            raise
        progress("这个 Worker 已经有房间对象（迁移标签已是 v1），改为只更新代码…")
    _upload(token, account_id, script_name, with_migrations=False)


def enable_workers_dev(token: str, account_id: str, script_name: str, progress=print) -> None:
    progress("开启 workers.dev 访问 …")
    _result(_request(token, "POST",
                     "/accounts/%s/workers/scripts/%s/subdomain" % (account_id, script_name),
                     {"enabled": True, "previews_enabled": False}), "开启 workers.dev")


def worker_url(token: str, account_id: str, script_name: str) -> str:
    result = _result(_request(token, "GET", "/accounts/%s/workers/subdomain" % account_id),
                     "读取 workers.dev 子域")
    subdomain = str((result or {}).get("subdomain", "")).strip()
    if not subdomain:
        raise DeployError("这个账号还没开通 workers.dev 子域，请在 Cloudflare 面板里先进入 Workers 页面")
    return "https://%s.%s.workers.dev" % (script_name, subdomain)


def deploy_all(token: str, script_name: str = relay_bundle.SCRIPT_NAME,
               account_id: str = "", progress=print) -> tuple[str, str]:
    """Verify the token, deploy the worker, enable workers.dev, return (url, account_name)."""
    verify_token(token)
    progress("Token 有效")
    account_id = account_id.strip()
    if account_id:
        # Pasting the account id by hand is the escape hatch when the token has no
        # "Account Settings: Read" permission and /accounts stays hidden.
        account_name = account_id
        progress("使用手动填写的账号 ID：%s" % account_id)
    else:
        accounts = list_accounts(token)
        account = accounts[0]
        account_id = str(account.get("id", ""))
        account_name = str(account.get("name", account_id))
        progress("账号：%s" % account_name)
    deploy_worker(token, account_id, script_name, progress)
    enable_workers_dev(token, account_id, script_name, progress)
    url = worker_url(token, account_id, script_name)
    progress("部署完成：%s" % url)
    return url, account_name
