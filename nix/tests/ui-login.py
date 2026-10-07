"""Drive the real web UI in a headless browser: log in and stay logged in.

Run by nix/tests/ui-login.nix against a booted appliance. Exits non-zero (with the request log) when the
session does not survive the first seconds after login or when any request is answered 401 — the class
of failure that curl from inside the machine cannot show, because the API services skip authentication
for loopback clients while a browser arrives through the gateway.
"""

import json
import sys

from playwright.sync_api import sync_playwright

base, user, password = sys.argv[1:4]
log = []
bus_frames = []  # frames received on the dashboard's socket.io subscription to the message bus


def on_websocket(ws):
    if "/v2/message_bus/socket.io/" in ws.url:
        ws.on("framereceived", lambda frame: bus_frames.append(str(frame)[:80]))

# The login form is re-rendered while the page settles, so set the values and press the button from
# inside the page instead of racing the layout.
FILL = """([u, p]) => {
  const set = (el, v) => { el.value = v; el.dispatchEvent(new Event('input', {bubbles: true})); };
  set(document.querySelector('input[type=text]'), u);
  set(document.querySelector('input[type=password]'), p);
}"""
CLICK_LOGIN = "() => [...document.querySelectorAll('button')].find(b => b.textContent.includes('Login')).click()"

with sync_playwright() as p:
    browser = p.chromium.launch(args=["--no-sandbox", "--disable-dev-shm-usage", "--disable-gpu"])
    page = browser.new_page(viewport={"width": 1400, "height": 900})
    page.on("response", lambda r: log.append((r.request.method, r.status, r.url.replace(base, ""))))
    page.on("console", lambda m: log.append(("console", m.type, m.text[:200])))
    page.on("websocket", on_websocket)

    page.goto(base + "/")
    page.wait_for_selector("input[type=text]", timeout=30000)
    page.wait_for_load_state("networkidle")
    page.wait_for_timeout(2000)
    page.evaluate(FILL, [user, password])
    page.evaluate(CLICK_LOGIN)
    page.wait_for_timeout(20000)  # long enough for the UI to fire its startup requests and any refresh/logout cycle

    url = page.url
    storage = page.evaluate("() => Object.fromEntries(Object.entries(localStorage))")
    browser.close()

unauthorized = [e for e in log if e[0] != "console" and e[1] == 401]
print("final url:", url)
print("localStorage keys:", sorted(storage))
print("401s:", unauthorized)
print("message bus frames:", len(bus_frames))

failed = []
if url.rstrip("/").endswith("#/login"):
    failed.append("logged out again: back on the login page")
if not storage.get("access_token"):
    failed.append("no access_token left in localStorage")
if unauthorized:
    failed.append(f"{len(unauthorized)} request(s) answered 401")
# the subscription is authenticated with a one-use ticket (message-bus patches 0007-0008, UI 0009):
# without one the bus refuses the handshake and the dashboard silently gets no events
if not bus_frames:
    failed.append("no message bus subscription: the socket.io WebSocket never received a frame")

if failed:
    print("FAILED:", "; ".join(failed))
    for entry in log:
        print("  ", *entry)
    sys.exit(1)
print("ok: logged in and stayed logged in")
