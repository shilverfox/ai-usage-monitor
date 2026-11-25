#!/usr/bin/env python3
"""抓取 Google 订阅信息（方案 / 状态 / 到期日 / 扣款记录 / 存储用量），
写入 UsageMonitor 的缓存文件，供菜单栏 app 展示。

用法:
    python3 scripts/fetch_google_subscription.py            # 无头刷新（默认）
    python3 scripts/fetch_google_subscription.py --visible  # 弹出窗口，用于重新登录
    python3 scripts/fetch_google_subscription.py --print    # 顺带打印结果

退出码:
    0  成功
    2  需要登录（缓存中的 lastError 会被写入，app 内据此提示）
    3  其他失败
"""

import argparse
import json
import os
import re
import sys
import time
from datetime import datetime

PROFILE_DIR = os.path.expanduser("~/.config/usagemonitor/gplay-profile")
CACHE_DIR = os.path.expanduser("~/.config/usagemonitor")
CACHE_PATH = os.path.join(CACHE_DIR, "subscriptions.json")
DEFAULT_PROXY = os.environ.get("UM_PROXY", "http://127.0.0.1:17890")

SUBS_URL = "https://play.google.com/store/account/subscriptions?hl=zh-CN"
STORAGE_URL = "https://one.google.com/storage?hl=zh-CN"
# 订单记录用 Play 的页面：pay.google.com 的活动页在自动化浏览器里始终不渲染
# （无头/有头、前台/后台、滚动均实测 120s 为空），Play 这页 12s 就能出完整列表
ORDERS_URL = "https://play.google.com/store/account/orderhistory?hl=zh-CN"


# ---------------------------------------------------------------- 抓取

def grab(proxy, visible):
    from playwright.sync_api import sync_playwright

    result = {"subs": "", "storage": "", "orders": "", "subsHtml": "", "needsLogin": False}
    with sync_playwright() as p:
        ctx = p.chromium.launch_persistent_context(
            PROFILE_DIR,
            headless=not visible,
            channel="chrome",
            proxy={"server": proxy},
            locale="zh-CN",
            timezone_id="Asia/Shanghai",
            viewport={"width": 1280, "height": 1200},
            args=["--disable-blink-features=AutomationControlled"],
        )
        page = ctx.pages[0] if ctx.pages else ctx.new_page()

        def visit(url, key, marker=None, max_wait=30):
            page.goto(url, wait_until="domcontentloaded", timeout=45000)
            deadline = time.time() + max_wait
            text = ""
            while time.time() < deadline:
                time.sleep(2)
                if "accounts.google.com" in page.url:
                    result["needsLogin"] = True
                    result[key] = ""
                    return
                try:
                    text = page.inner_text("body")
                except Exception:
                    text = ""
                if marker is None or marker in text:
                    break
            # 再等一轮网络空闲，让数字稳定
            try:
                page.wait_for_load_state("networkidle", timeout=8000)
            except Exception:
                pass
            try:
                result[key] = page.inner_text("body")
            except Exception:
                result[key] = text or ""

        visit(SUBS_URL, "subs", marker="订阅", max_wait=30)
        if result["needsLogin"]:
            ctx.close()
            return result
        try:
            result["subsHtml"] = page.content()
        except Exception:
            result["subsHtml"] = ""
        visit(STORAGE_URL, "storage", marker="存储空间", max_wait=30)
        visit(ORDERS_URL, "orders", marker="订单记录", max_wait=40)
        ctx.close()
    return result


# ---------------------------------------------------------------- 解析

def parse_subs(text, html=""):
    out = {}
    lines = [l.strip() for l in text.splitlines()]
    status_words = ("活跃", "已取消", "已过期", "待处理", "暂停")
    # 「活跃」本身也是板块标题，所以状态必须取「套餐名之后」出现的那个词
    plan_index = -1
    for i, line in enumerate(lines):
        if line == "活跃" and i + 2 < len(lines):
            out["provider"] = lines[i + 1]
            out["plan"] = lines[i + 2]
            plan_index = i + 2
            break
    status_text = ""
    if plan_index >= 0:
        for line in lines[plan_index + 1:]:
            if line in status_words:
                status_text = line
                break
    m = re.search(r"您的订阅期将于\s*(\d{4})年(\d{1,2})月(\d{1,2})日结束", text)
    if m:
        out["periodEnd"] = "%04d-%02d-%02d" % (int(m.group(1)), int(m.group(2)), int(m.group(3)))
    # 续订价格在「重新订阅」弹窗的 JSON 里，可见文本抓不到，得从 HTML 取
    m = re.search(r"US\$([\d.,]+)\s*/\s*(年|月)", html or text)
    if m:
        out["renewalPrice"] = "US$" + m.group(1)
        out["renewalCycle"] = "year" if m.group(2) == "年" else "month"
    if out.get("provider"):
        out["statusText"] = status_text or "未知"
        out["status"] = {
            "活跃": "active",
            "已取消": "cancelled",
            "已过期": "expired",
            "待处理": "pending",
            "暂停": "paused",
        }.get(status_text, "unknown")
        # 已取消 = 到期不续订；活跃 = 到期自动续订
        out["autoRenew"] = out["status"] == "active"
    return out


def to_gb(num, unit):
    f = float(num)
    return f * 1024 if unit.upper() == "TB" else f


def parse_storage(text):
    out = {}
    m = re.search(r"已使用\s*([\d.]+)\s*(GB|TB|MB)，共\s*([\d.]+)\s*(GB|TB|MB)", text)
    if m:
        used_gb = to_gb(m.group(1), m.group(2))
        total_gb = to_gb(m.group(3), m.group(4))
        out["usedText"] = "%s %s" % (m.group(1), m.group(2))
        out["totalText"] = "%s %s" % (m.group(3), m.group(4))
        out["usedGB"] = round(used_gb, 3)
        out["totalGB"] = round(total_gb, 3)
        out["percent"] = round(used_gb / total_gb * 100, 2) if total_gb else None
    m = re.search(r"您已获得\s*([\d.]+)\s*(TB|GB) 的存储空间", text)
    if m:
        out["planStorage"] = "%s %s" % (m.group(1), m.group(2))
    breakdown = []
    for label, key in (("Google 云端硬盘", "Drive"), ("Gmail", "Gmail"), ("Google 相册", "Photos")):
        mm = re.search(
            re.escape(label) + r"\s*\n\s*([\d.]+)\s*(GB|TB|MB)", text
        )
        if mm:
            breakdown.append(
                {
                    "name": label,
                    "sizeText": "%s %s" % (mm.group(1), mm.group(2)),
                    "sizeGB": round(to_gb(mm.group(1), mm.group(2)), 3),
                }
            )
    if breakdown:
        out["breakdown"] = breakdown
    mm = re.search(r"当前方案\s*\n\s*结束时间：(\d{4})年(\d{1,2})月(\d{1,2})日", text)
    if mm:
        out["planEnd"] = "%04d-%02d-%02d" % (int(mm.group(1)), int(mm.group(2)), int(mm.group(3)))
    mm = re.search(r"当前方案[\s\S]{0,120}?(Google AI [A-Za-z]+)", text)
    if mm:
        out["planName"] = mm.group(1)
    return out


ORDER_BLOCK_RE = re.compile(
    r"([^\n]+)\n(?:已退款\n)?(\d{4})年(\d{1,2})月(\d{1,2})日\n(US\$[\d.,]+)"
)


def parse_orders(text, today=None):
    """Play 订单记录页：每笔订单是「名称 / [已退款] / 日期 / 金额」四行一组。"""
    today = today or datetime.now()
    charges = []
    seen = set()
    for m in ORDER_BLOCK_RE.finditer(text):
        title = m.group(1).strip()
        date_str = "%04d-%02d-%02d" % (int(m.group(2)), int(m.group(3)), int(m.group(4)))
        key = (title, date_str, m.group(5))
        if key in seen:
            continue
        seen.add(key)
        # 「已退款」夹在名称和日期之间，正则里是可选的，用切片判断
        block = text[m.start():m.end()]
        charges.append(
            {
                "date": date_str,
                "amount": m.group(5),
                "title": title,
                "detail": title,
                "refunded": "已退款" in block,
            }
        )
    charges.sort(key=lambda c: c["date"], reverse=True)
    return charges


# ---------------------------------------------------------------- 主流程

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--visible", action="store_true", help="弹出浏览器窗口（重新登录用）")
    ap.add_argument("--print", dest="do_print", action="store_true")
    ap.add_argument("--proxy", default=DEFAULT_PROXY)
    args = ap.parse_args()

    os.makedirs(CACHE_DIR, exist_ok=True)
    previous = {}
    if os.path.exists(CACHE_PATH):
        try:
            with open(CACHE_PATH, encoding="utf-8") as f:
                previous = json.load(f)
        except Exception:
            previous = {}

    try:
        raw = grab(args.proxy, args.visible)
    except Exception as e:
        payload = dict(previous)
        payload["lastError"] = "抓取失败: %s" % e
        payload["lastAttemptAt"] = datetime.now().astimezone().isoformat(timespec="seconds")
        with open(CACHE_PATH, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, indent=2)
        print(payload["lastError"], file=sys.stderr)
        return 3

    if raw["needsLogin"]:
        payload = dict(previous)
        payload["needsLogin"] = True
        payload["lastError"] = "登录态失效，需要重新登录"
        payload["lastAttemptAt"] = datetime.now().astimezone().isoformat(timespec="seconds")
        with open(CACHE_PATH, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, indent=2)
        print("需要登录：请运行 --visible 手动登录一次", file=sys.stderr)
        return 2

    sub = parse_subs(raw["subs"], raw.get("subsHtml", ""))
    storage = parse_storage(raw["storage"])
    charges = parse_orders(raw["orders"])

    # 订单页偶发抓不到：保留上次的扣款记录，但标记其抓取时间
    if charges:
        charges_at = datetime.now().astimezone().isoformat(timespec="seconds")
    else:
        charges = previous.get("charges") or []
        charges_at = previous.get("chargesFetchedAt")

    payload = {
        "schemaVersion": 1,
        "fetchedAt": datetime.now().astimezone().isoformat(timespec="seconds"),
        "needsLogin": False,
        "lastError": None,
        "subscription": sub or previous.get("subscription") or {},
        "storage": storage or previous.get("storage") or {},
        "charges": charges,
        "chargesFetchedAt": charges_at,
    }
    with open(CACHE_PATH, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)

    if args.do_print:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        s = payload["subscription"]
        print(
            "OK %s / %s / %s / 到期 %s / 用量 %s"
            % (
                s.get("provider", "?"),
                s.get("plan", "?"),
                s.get("statusText", "?"),
                s.get("periodEnd", "?"),
                payload["storage"].get("usedText", "?"),
            )
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
