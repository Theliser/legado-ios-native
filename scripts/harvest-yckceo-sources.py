#!/usr/bin/env python3
"""抓取阅读源仓库（yckceo）最近发布的文本书源，供 `YckceoLiveTests` 做联网体检。

用法：
    python3 scripts/harvest-yckceo-sources.py            # 默认最近 40 个候选
    YCKCEO_LIMIT=20 python3 scripts/harvest-yckceo-sources.py

输出目录：`.context/live-sources/`（已 gitignore）
然后运行：
    TEST_RUNNER_RUN_YCKCEO_LIVE=1 \
    TEST_RUNNER_YCKCEO_LIMIT=12 \
    xcodebuild test -project Legado.xcodeproj -scheme Legado \
      -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
      -only-testing:LegadoTests/YckceoLiveTests
"""

import json
import os
import re
import sys
import urllib.request

BASE = "https://www.yckceo.com/yuedu/shuyuan"
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/124 Safari/537.36"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, ".context", "live-sources")
LIMIT = int(os.environ.get("YCKCEO_LIMIT", "40"))


def get(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read().decode("utf-8", "replace")


def main() -> int:
    os.makedirs(OUT, exist_ok=True)
    html = get(BASE + "/index.html")
    items = []
    for m in re.finditer(
        r'<input type="checkbox"[^>]*value="(\d+)"[^>]*>.*?'
        r'<h2><a href="[^"]*">(.*?)</a>\s*'
        r'<p class="m-right"[^>]*>(.*?)</p>',
        html, re.S,
    ):
        sid = m.group(1)
        name = re.sub(r"<[^>]+>", "", m.group(2)).strip()
        age = m.group(3).strip()
        items.append((sid, name, age))

    # 先排除短剧/漫画/听书；最近发布的排在最前
    preferred = [x for x in items if not any(
        k in x[1] for k in ("短剧", "漫画", "听书", "有声"))]
    saved = []
    for sid, name, age in preferred[:LIMIT]:
        try:
            payload = json.loads(get(f"{BASE}/jsons?id={sid}"))
        except Exception as exc:  # noqa: BLE001
            print(f"skip {sid} {name}: {exc}")
            continue
        if not payload:
            continue
        source = payload[0]
        host = re.sub(r"https?://([^/]+).*", r"\1", source.get("bookSourceUrl", "unknown"))
        filename = f"{sid}_{host}.json".replace("/", "_")
        with open(os.path.join(OUT, filename), "w", encoding="utf-8") as f:
            json.dump(source, f, ensure_ascii=False, indent=2)
        saved.append((sid, source.get("bookSourceName"), age, host))
        print(f"saved {sid} {age} {host}")

    print(f"\n{len(saved)} sources -> {OUT}")
    return 0 if saved else 1


if __name__ == "__main__":
    sys.exit(main())
