#!/usr/bin/env python3
# Backfill Vitalis from Health Auto Export's local MCP server (Premium; the app open on screen, same Wi-Fi): pull
# day-grouped metrics and workouts in chunks, newest first, and push each chunk to /ingest. Prints counts only.
#   HAE_URL=http://<phone-ip>:9000/mcp HAE_TOKEN=<server token> VITALIS_URL=https://<host>/ingest VITALIS_TOKEN=<ingest token> \
#     python3 scripts/backfill-from-hae-mcp.py        # DRY=1 to pull without pushing; FLOOR, END, CHUNK_DAYS to bound it
import json, os, sys, urllib.request
from datetime import date, timedelta

HAE = os.environ["HAE_URL"]
VITALIS = os.environ["VITALIS_URL"]
CHUNK_DAYS = int(os.environ.get("CHUNK_DAYS", 60))
FLOOR = date.fromisoformat(os.environ.get("FLOOR", "2015-01-01"))
END = date.fromisoformat(os.environ.get("END", date.today().isoformat()))
STOP_AFTER_EMPTY = int(os.environ.get("STOP_AFTER_EMPTY", 4))
DRY = os.environ.get("DRY") == "1"
hae_auth = f"Bearer {os.environ['HAE_TOKEN']}"
ingest_tok = os.environ.get("VITALIS_TOKEN", "")

session = None
rid = 0
def rpc(method, params=None, notify=False):
    global session, rid
    rid += 1
    body = {"jsonrpc": "2.0", "method": method, **({} if notify else {"id": rid}), **({"params": params} if params is not None else {})}
    h = {"content-type": "application/json", "accept": "application/json, text/event-stream", "authorization": hae_auth, "mcp-protocol-version": "2025-06-18"}
    if session: h["mcp-session-id"] = session
    req = urllib.request.Request(HAE, data=json.dumps(body).encode(), headers=h, method="POST")
    with urllib.request.urlopen(req, timeout=300) as r:
        session = r.headers.get("mcp-session-id") or session
        text = r.read().decode()
    if notify or not text.strip(): return None
    if text.lstrip().startswith("{"): msg = json.loads(text)
    else: msg = next(json.loads(l[5:]) for l in text.splitlines() if l.startswith("data:") and '"id"' in l)
    if "error" in msg: raise RuntimeError(f"{method}: {msg['error']}")
    return msg["result"]

def tool(name, args):
    res = rpc("tools/call", {"name": name, "arguments": args})
    if res.get("isError"): raise RuntimeError(f"{name}: {res['content'][0]['text'][:200]}")
    if res.get("structuredContent"): return res["structuredContent"]
    return json.loads(res["content"][0]["text"])

def push(payload, label):
    body = json.dumps(payload).encode()
    if DRY: return {"dry": True, "bytes": len(body)}
    req = urllib.request.Request(VITALIS, data=body, method="POST", headers={"content-type": "application/json",
        "authorization": f"Bearer {ingest_tok}", "automation-name": f"backfill {label}", "automation-aggregation": "days"})
    with urllib.request.urlopen(req, timeout=300) as r:
        return json.loads(r.read())

rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "vitalis-backfill", "version": "1"}})
rpc("notifications/initialized", notify=True)

empty, end, total = 0, END, {"metric_days": 0, "sleep_nights": 0, "workouts": 0}
while end >= FLOOR and empty < STOP_AFTER_EMPTY:
    start = max(FLOOR, end - timedelta(days=CHUNK_DAYS - 1))
    m = tool("get_health_metrics", {"start": start.isoformat(), "end": end.isoformat(), "interval": "days", "aggregate": True})
    w = tool("get_workouts", {"start": start.isoformat(), "end": end.isoformat(), "includeMetadata": False, "includeRoutes": False})
    metrics = (m.get("data") or {}).get("metrics", [])
    workouts = (w.get("data") or {}).get("workouts", [])
    rows = sum(len(x.get("data", [])) for x in metrics)
    label = f"{start}..{end}"
    if rows == 0 and not workouts:
        empty += 1
        print(f"{label}: empty")
    else:
        empty = 0
        r = push({"data": {"metrics": metrics, "workouts": workouts}}, label)
        c = r.get("counts", {})
        for k in total: total[k] += c.get(k, 0)
        warn = r.get("warnings", [])
        print(f"{label}: {len(metrics)} metrics, {rows} rows, {len(workouts)} workouts -> {c}{' dup' if r.get('duplicate') else ''}{f' warnings: {warn[:3]}' if warn else ''}", flush=True)
    end = start - timedelta(days=1)
print("total", total)
