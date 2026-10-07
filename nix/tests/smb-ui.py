"""Share accounts and share access through the real web UI (check smb-ui, T14).

Run by nix/tests/smb-ui.nix against a booted appliance: log in, open Files, go to Shared, open
"Share accounts" and add an account; then, in /DATA, right-click the folder "Media", choose Share, pick
"Only one account" and the new account, and press Share. The test script then checks through the API
that the share exists and is restricted to that account (PRs ReCasaOS-UI#8, ReCasaOS-UI#9).
"""

import sys

from playwright.sync_api import sync_playwright

base, user, password, account, account_password = sys.argv[1:6]

FILL = """([u, p]) => {
  const set = (el, v) => { el.value = v; el.dispatchEvent(new Event('input', {bubbles: true})); };
  set(document.querySelector('input[type=text]'), u);
  set(document.querySelector('input[type=password]'), p);
}"""
CLICK_LOGIN = "() => [...document.querySelectorAll('button')].find(b => b.textContent.includes('Login')).click()"

log = []


def step(page, name):
    print(f"--- {name}", flush=True)
    page.wait_for_timeout(1000)


def dump(page, name):
    try:
        page.screenshot(path=f"/tmp/{name}.png", full_page=True)
    except Exception:
        pass
    print(page.evaluate("() => document.body.innerText")[:4000])


with sync_playwright() as p:
    browser = p.chromium.launch(args=["--no-sandbox", "--disable-dev-shm-usage", "--disable-gpu"])
    page = browser.new_page(viewport={"width": 1400, "height": 1000})
    page.on("response", lambda r: log.append((r.request.method, r.status, r.url.replace(base, ""))))
    try:
        page.goto(base + "/")
        page.wait_for_selector("input[type=text]", timeout=30000)
        page.wait_for_load_state("networkidle")
        page.wait_for_timeout(2000)
        page.evaluate(FILL, [user, password])
        page.evaluate(CLICK_LOGIN)

        step(page, "open Files")
        files = page.locator("#app-Files img").first
        files.wait_for(state="visible", timeout=60000)
        page.wait_for_timeout(3000)
        files.click()

        step(page, "open Shared")
        shared = page.get_by_text("Shared", exact=True).first
        shared.wait_for(state="visible", timeout=60000)
        shared.click()

        step(page, "open Share accounts")
        page.get_by_role("button", name="Share accounts").click(timeout=30000)
        modal = page.locator(".samba-users-modal")
        modal.wait_for(state="visible", timeout=15000)
        modal.get_by_placeholder("Account name").fill(account)
        modal.get_by_placeholder("Password").fill(account_password)
        modal.get_by_role("button", name="Add").click()
        modal.get_by_text(account, exact=True).wait_for(state="visible", timeout=30000)
        modal.get_by_role("button", name="Close").click()
        modal.wait_for(state="hidden", timeout=15000)

        step(page, "browse to /DATA")
        page.get_by_text("DATA", exact=True).first.click(timeout=30000)
        folder = page.locator(".node-card", has=page.locator("p.title", has_text="Media")).first
        folder.wait_for(state="visible", timeout=30000)

        step(page, "share Media to the account")
        folder.click(button="right")
        page.locator("[role=menuitem]", has_text="Share").filter(has_not_text="UnShare").first.click(timeout=15000)
        access = page.locator(".share-access-modal")
        access.wait_for(state="visible", timeout=15000)
        access.get_by_text("Only one account").click()
        access.locator("select").select_option(account)
        access.get_by_role("button", name="Share").click()
        access.wait_for(state="hidden", timeout=30000)
        print("shared through the UI", flush=True)
    except Exception as error:  # noqa: BLE001 — report everything the page shows
        print(f"FAILED: {error}")
        dump(page, "smb-ui-failure")
        for entry in log[-40:]:
            print(entry)
        sys.exit(1)
    finally:
        browser.close()

bad = [entry for entry in log if entry[1] >= 400 and "/samba/" in entry[2]]
if bad:
    print("failed share requests:", bad)
    sys.exit(1)
