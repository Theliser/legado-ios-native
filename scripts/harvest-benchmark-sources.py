#!/usr/bin/env python3
"""从 yckceo 书源站抓「最近」的候选书源到基准池。

用法：
    ./scripts/harvest-benchmark-sources.py                 # 默认抓 40 个最新条目
    ./scripts/harvest-benchmark-sources.py --count 60
    ./scripts/harvest-benchmark-sources.py --proxy http://127.0.0.1:10808

产出的 JSON 落在 LegadoTests/BenchmarkKit/pool/，只是**候选**；
能不能用要由 SourceBenchmarkTests 的录制流程真跑一遍才知道。
"""

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

BASE = "https://www.yckceo.com"
INDEX = f"{BASE}/yuedu/shuyuan/index.html"
JSON_API = BASE + "/yuedu/shuyuan/json/id/{id}.json"

ROOT = Path(__file__).resolve().parent.parent
POOL = ROOT / "LegadoTests" / "BenchmarkKit" / "pool"

# 明显不适合进基准的：成人内容、非文本（音频/文件/图片）、无搜索入口
ADULT_MARKERS = ("🔞", "成人", "色", "肉文", "黄区", "福利", "里番")
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/124.0 Safari/537.36")


def build_opener(proxy: str | None):
    handlers = []
    if proxy:
        handlers.append(urllib.request.ProxyHandler({"http": proxy, "https": proxy}))
    return urllib.request.build_opener(*handlers)


def fetch(opener, url: str, timeout: int = 25) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with opener.open(req, timeout=timeout) as resp:
        return resp.read()


def list_ids(opener) -> list[int]:
    html = fetch(opener, INDEX).decode("utf-8", "ignore")
    ids = {int(m) for m in re.findall(r"/yuedu/shuyuan/content/id/(\d+)\.html", html)}
    return sorted(ids, reverse=True)


def looks_usable(source: dict) -> tuple[bool, str]:
    if not isinstance(source, dict):
        return False, "不是对象"
    url = (source.get("bookSourceUrl") or "").split("#")[0]
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in ("http", "https"):
        return False, "源地址不是 http"
    # 书源里常见 `https://host##别名` 这种「同一站点的第二个源」写法，host 不合法
    if not re.match(r"^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$", parsed.hostname or ""):
        return False, "源地址主机名不合法"
    if source.get("bookSourceType", 0) != 0:
        return False, "非文本源"
    name = str(source.get("bookSourceName") or "")
    if any(marker in name for marker in ADULT_MARKERS):
        return False, "成人内容"
    if not (source.get("searchUrl") or source.get("mainJs")):
        return False, "没有搜索入口"
    for key in ("ruleSearch", "ruleToc", "ruleContent"):
        if not source.get(key):
            return False, f"缺 {key}"
    body = (source.get("searchUrl") or "") + (source.get("ruleContent", {}) or {}).get("content", "") or ""
    # 需要 WebView / 登录态的源在基准里不可复现，先排除
    if "webView" in body or "webview" in body.lower():
        return False, "依赖 WebView"
    return True, ""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--count", type=int, default=40, help="最多保存多少个可用候选")
    parser.add_argument("--scan", type=int, default=160, help="最多扫多少个最新条目")
    parser.add_argument("--proxy", default=os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy"))
    args = parser.parse_args()

    opener = build_opener(args.proxy)
    POOL.mkdir(parents=True, exist_ok=True)

    print(f"取列表 {INDEX}")
    ids = list_ids(opener)[: args.scan]
    print(f"最新 {len(ids)} 个条目：{ids[:5]} …")

    saved, rejected = 0, {}
    for sid in ids:
        if saved >= args.count:
            break
        try:
            raw = fetch(opener, JSON_API.format(id=sid))
            data = json.loads(raw.decode("utf-8", "ignore"))
        except (urllib.error.URLError, json.JSONDecodeError, TimeoutError) as error:
            rejected[f"id={sid}"] = f"下载/解析失败 {error}"
            continue

        if isinstance(data, list):
            data = data[0] if data else {}
        ok, reason = looks_usable(data)
        if not ok:
            rejected[f"id={sid}"] = reason
            continue

        host = re.sub(r"^https?://", "", data["bookSourceUrl"]).split("/")[0]
        target = POOL / f"{sid}_{re.sub(r'[^A-Za-z0-9.-]', '_', host)}.json"
        data.pop("bookSourceComment", None)
        target.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
        saved += 1
        print(f"  + {data.get('bookSourceName', '?')[:22]:24} {data['bookSourceUrl'][:44]}")
        time.sleep(0.2)

    print(f"\n保存 {saved} 个候选到 {POOL}")
    if rejected:
        reasons = {}
        for reason in rejected.values():
            key = reason.split(" ")[0]
            reasons[key] = reasons.get(key, 0) + 1
        print("被排除：" + "，".join(f"{k}×{v}" for k, v in sorted(reasons.items(), key=lambda x: -x[1])))
    print("\n下一步：TEST_RUNNER_BENCH_RECORD=1 xcodebuild test … -only-testing:LegadoTests/SourceBenchmarkTests/testRecordFromPool")
    return 0


if __name__ == "__main__":
    sys.exit(main())
