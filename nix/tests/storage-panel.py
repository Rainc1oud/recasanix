"""Open the web UI's storage manager in a headless browser and check what a user sees.

Run by nix/tests/storage-manager.nix against a booted appliance: log in, press the gear of the Storage
widget, and read the panel. Phase "blank" (two blank disks, no pool): the Storage tab shows the system
volume, the Drive tab shows both blank disks, and pressing Create Storage → Format and create actually
creates one — a success toast, and the panel returns to the list (not stuck on "Creation in progress",
PR ReCasaOS-UI#13). Phase "pool" (both disks now used, one JBOD pool made via the API for the second disk):
the Storage tab shows the pool.

In both phases the three requests the panel makes must be answered (not 404), which is the whole
point: before this service existed they were 404 and the panel was defunct.
"""

import re
import sys

from playwright.sync_api import sync_playwright

base, user, password, phase = sys.argv[1:5]
log = []

FILL = """([u, p]) => {
  const set = (el, v) => { el.value = v; el.dispatchEvent(new Event('input', {bubbles: true})); };
  set(document.querySelector('input[type=text]'), u);
  set(document.querySelector('input[type=password]'), p);
}"""
CLICK_LOGIN = "() => [...document.querySelectorAll('button')].find(b => b.textContent.includes('Login')).click()"
GEAR = (
    "xpath=//div[contains(@class,'widget-header')]"
    "[.//div[contains(@class,'widget-title')][normalize-space(.)='Storage']]"
    "//div[contains(@class,'widget-icon-button')]"
)

failures = []
storage_tab = drive_tab = toast_text = creating = create_form = None


def check(condition, message):
    if not condition:
        failures.append(message)


try:
    with sync_playwright() as p:
        browser = p.chromium.launch(args=["--no-sandbox", "--disable-dev-shm-usage", "--disable-gpu"])
        page = browser.new_page(viewport={"width": 1400, "height": 1000})
        page.on("response", lambda r: log.append((r.request.method, r.status, r.url.replace(base, ""))))

        page.goto(base + "/")
        page.wait_for_selector("input[type=text]", timeout=30000)
        page.wait_for_load_state("networkidle")
        page.wait_for_timeout(2000)
        page.evaluate(FILL, [user, password])
        page.evaluate(CLICK_LOGIN)

        # the dashboard, then the gear of the Storage widget
        gear = page.locator(GEAR).first
        gear.wait_for(state="visible", timeout=60000)
        page.wait_for_timeout(3000)
        gear.click()

        modal = page.locator(".storage-modal")
        modal.wait_for(state="visible", timeout=30000)
        page.wait_for_load_state("networkidle")
        page.wait_for_timeout(3000)

        storage_tab = modal.inner_text()
        modal.get_by_text("Drive", exact=True).first.click()
        page.wait_for_timeout(1500)
        drive_tab = modal.inner_text()

        if phase == "blank":
            modal.get_by_text("Storage", exact=True).first.click()
            page.wait_for_timeout(800)
            modal.get_by_role("button", name="Create Storage", exact=True).click()
            page.wait_for_timeout(1500)
            create_form = modal.inner_text()
            print("--- create form ---\n" + create_form)
            print("buttons:", modal.locator("button").all_inner_texts())
            modal.get_by_role("button", name=re.compile(r"^Format and create$", re.I)).click()
            # the toast is up for three seconds: read it as soon as it shows
            toast = page.locator(".toast").first
            toast.wait_for(state="visible", timeout=15000)
            toast_text = toast.inner_text()
            # the actual create takes a few seconds (mkfs, udev, bringing the pool online); give the
            # panel time to refresh before checking it is not stuck (ReCasaOS-UI#13's whole point)
            page.wait_for_timeout(8000)
            creating = "Creation in progress" in modal.inner_text()
            storage_tab = modal.inner_text()

        browser.close()
except Exception:
    print('STEP FAILED; what was seen so far:')
    print('panel requests:', [e for e in log if any(x in e[2] for x in ('/v1/disks', '/v1/storage', '/v2/local_storage'))])
    print('--- Storage tab ---\n' + str(storage_tab))
    print('--- Drive tab ---\n' + str(drive_tab))
    raise

panel_calls = [e for e in log if any(s in e[2] for s in ("/v1/disks", "/v1/storage", "/v2/local_storage"))]
print("panel requests:", panel_calls)
print("--- Storage tab ---\n" + storage_tab)
print("--- Drive tab ---\n" + drive_tab)

# the requests the panel makes are answered
for needle in ("/v1/disks", "/v1/storage", "/v2/local_storage/merge"):
    calls = [e for e in panel_calls if needle in e[2] and e[0] == "GET"]
    check(calls, f"the panel never asked for {needle}")
    check(all(e[1] == 200 for e in calls), f"{needle} was answered {[e[1] for e in calls]}")

# the system volume is named by its filesystem label and tagged "OS"; it sits on the system drive
check("vda" in storage_tab and "OS" in storage_tab, "the Storage tab does not show the system volume")

if phase == "blank":
    check("vdb" in drive_tab and "vdc" in drive_tab, "the Drive tab does not list both blank disks")
    check("System" in drive_tab, "the Drive tab does not show the system drive")
    print("--- toast shown after creating ---\n" + str(toast_text))
    check(toast_text and "success" in toast_text.lower(), "creating a storage did not show a success toast")
    check(not creating, "the panel is stuck on 'Creation in progress' after creating (PR ReCasaOS-UI#13)")
    check("recasanix-data" in str(storage_tab), "the Storage tab does not show the newly created pool")
elif phase == "pool":
    check("recasanix-data" in storage_tab, "the Storage tab does not show the pool")
    check("btrfs" in storage_tab.lower(), "the pool's filesystem is not shown")
    check("vdb" in drive_tab and "vdc" in drive_tab, "the Drive tab does not list the pool's disks")
else:
    failures.append(f"unknown phase {phase}")

if failures:
    print("FAILED:", "; ".join(failures))
    for entry in log:
        print("  ", *entry)
    sys.exit(1)
print(f"ok: storage manager ({phase})")
