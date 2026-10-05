package main

import (
	"bytes"
	"crypto/ecdsa"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// testServer is the full handler chain of the service — authentication in front of the routes — over a
// fixture, with a signing key the test holds.
func testServer(t *testing.T, fixtureName string) (h http.Handler, priv *ecdsa.PrivateKey, bearer string) {
	t.Helper()
	inv, _ := testInventory(t, fixtureName, baseConfig(""))
	priv = newKey(t)
	api := &API{inv: inv, log: discardLog()}
	h = newAuthenticator(staticKey{key: &priv.PublicKey}).Middleware(api.Handler())
	bearer = "Bearer " + token(t, priv, tokenOpts{issuer: "casaos", expires: in(time.Hour)})
	return h, priv, bearer
}

func do(h http.Handler, method, target, bearer string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, target, strings.NewReader("{}"))
	if bearer != "" {
		r.Header.Set("Authorization", bearer)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

func decode(t *testing.T, w *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &m); err != nil {
		t.Fatalf("not JSON: %v: %s", err, w.Body.String())
	}
	return m
}

func TestEveryRouteRequiresAuthentication(t *testing.T) {
	h, _, _ := testServer(t, "vm-blank-disk.json")
	for _, target := range []string{"/v1/disks", "/v1/disks/usb", "/v1/storage", "/v1/storage?system=show", "/v2/local_storage/merge", "/v2/local_storage/mount", "/anything/else"} {
		for _, method := range []string{"GET", "POST", "PUT", "DELETE"} {
			if w := do(h, method, target, ""); w.Code != http.StatusUnauthorized {
				t.Errorf("%s %s without a token: %d", method, target, w.Code)
			}
		}
	}
}

func TestDisksEndpoint(t *testing.T) {
	h, _, bearer := testServer(t, "vm-blank-disk.json")
	w := do(h, "GET", "/v1/disks", bearer)
	if w.Code != 200 {
		t.Fatalf("status %d: %s", w.Code, w.Body)
	}
	m := decode(t, w)
	if m["success"] != float64(200) || m["message"] != "ok" {
		t.Fatalf("envelope = %v", m)
	}
	data := m["data"].(map[string]any)
	disks, avail := data["disks"].([]any), data["avail"].([]any)
	if len(disks) != 3 || len(avail) != 1 {
		t.Fatalf("disks=%d avail=%d", len(disks), len(avail))
	}
	blank := avail[0].(map[string]any)
	// every field the UI reads is present, with the type it expects
	for _, f := range []string{"name", "size", "model", "health", "temperature", "disk_type", "need_format", "serial", "path", "children_number", "children", "supported"} {
		if _, ok := blank[f]; !ok {
			t.Errorf("drive lacks %q", f)
		}
	}
	if blank["name"] != "vdb" || blank["need_format"] != true || blank["children"] == nil {
		t.Fatalf("blank drive = %v", blank)
	}
}

func TestStorageEndpoint(t *testing.T) {
	h, _, bearer := testServer(t, "image-with-pool.json")

	m := decode(t, do(h, "GET", "/v1/storage?system=show", bearer))
	list := m["data"].([]any)
	if len(list) != 2 {
		t.Fatalf("storage = %v", list)
	}
	first := list[0].(map[string]any)
	if first["disk_name"] != "System" {
		t.Fatalf("first = %v", first)
	}
	vol := list[1].(map[string]any)["children"].([]any)[0].(map[string]any)
	for _, f := range []string{"uuid", "mount_point", "size", "avail", "used", "type", "path", "drive_name", "label", "persisted_in"} {
		if _, ok := vol[f].(string); !ok {
			t.Errorf("volume field %q is not a string: %v", f, vol[f])
		}
	}

	// without ?system the system disk is left out
	m = decode(t, do(h, "GET", "/v1/storage", bearer))
	if got := len(m["data"].([]any)); got != 1 {
		t.Fatalf("without ?system=show: %d disks", got)
	}
}

func TestNoStorageIsAnEmptyListNotNull(t *testing.T) {
	h, _, bearer := testServer(t, "vm-blank-disk.json")
	// the VM fixture's only mounted non-system volume is the hidden state disk
	w := do(h, "GET", "/v1/storage", bearer)
	if !strings.Contains(w.Body.String(), `"data":[]`) {
		t.Fatalf("body = %s", w.Body)
	}
}

func TestUSBAndMergeAreEmptyNotMissing(t *testing.T) {
	h, _, bearer := testServer(t, "vm-blank-disk.json")
	if w := do(h, "GET", "/v1/disks/usb", bearer); w.Code != 200 || !strings.Contains(w.Body.String(), `"data":[]`) {
		t.Fatalf("usb: %d %s", w.Code, w.Body)
	}
	w := do(h, "GET", "/v2/local_storage/merge", bearer)
	m := decode(t, w)
	if w.Code != 200 || m["message"] != "ok" || len(m["data"].([]any)) != 0 {
		t.Fatalf("merge: %d %s", w.Code, w.Body)
	}
	if _, has := m["success"]; has {
		t.Fatal("the v2 format has no success field")
	}
}

func TestChangesToAnExistingStorageAreRefusedClearly(t *testing.T) {
	// POST /v1/storage (creating a new one) is deliberately not in this list: it is supported, see
	// TestCreateStorage*.
	h, _, bearer := testServer(t, "vm-blank-disk.json")
	changes := []struct{ method, target string }{
		{"PUT", "/v1/storage"}, {"DELETE", "/v1/storage"},
		{"DELETE", "/v1/disks"}, {"DELETE", "/v1/disks/usb"}, {"POST", "/v1/disks"},
		{"POST", "/v2/local_storage/mount"}, {"PUT", "/v2/local_storage/mount"}, {"DELETE", "/v2/local_storage/mount"},
		{"POST", "/v2/local_storage/merge"}, {"POST", "/v2/local_storage/merge/init"},
	}
	for _, c := range changes {
		w := do(h, c.method, c.target, bearer)
		if w.Code != http.StatusNotImplemented {
			t.Errorf("%s %s: %d, want 501", c.method, c.target, w.Code)
			continue
		}
		m := decode(t, w)
		if !strings.Contains(m["message"].(string), "not available yet") {
			t.Errorf("%s %s: message does not say why: %v", c.method, c.target, m["message"])
		}
	}
}

func TestUnknownReadsAreNotFound(t *testing.T) {
	h, _, bearer := testServer(t, "vm-blank-disk.json")
	for _, target := range []string{"/v1/disks/nope", "/v1/storage/nope", "/v2/local_storage/mount", "/v2/local_storage/other"} {
		if w := do(h, "GET", target, bearer); w.Code != http.StatusNotFound {
			t.Errorf("GET %s: %d", target, w.Code)
		}
	}
}

func TestResponsesAreNotCacheable(t *testing.T) {
	h, _, bearer := testServer(t, "vm-blank-disk.json")
	w := do(h, "GET", "/v1/disks", bearer)
	if w.Header().Get("Cache-Control") != "no-store" || w.Header().Get("Content-Type") != "application/json" || w.Header().Get("X-Content-Type-Options") != "nosniff" {
		t.Fatalf("headers = %v", w.Header())
	}
}

func TestALsblkFailureIsAnErrorWithoutDetails(t *testing.T) {
	inv, run := testInventory(t, "vm-blank-disk.json", baseConfig(""))
	run.errs[lsblkCall] = http.ErrAbortHandler
	priv := newKey(t)
	h := newAuthenticator(staticKey{key: &priv.PublicKey}).Middleware((&API{inv: inv, log: discardLog()}).Handler())
	w := do(h, "GET", "/v1/disks", "Bearer "+token(t, priv, tokenOpts{issuer: "casaos", expires: in(time.Hour)}))
	if w.Code != 500 || strings.Contains(w.Body.String(), "lsblk") || strings.Contains(w.Body.String(), "Abort") {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
}

// --- creating storage --------------------------------------------------------------------------------

func TestCreateStorageSucceeds(t *testing.T) {
	h, run, bearer := testServerWithCreator(t, "vm-blank-disk.json")
	body, _ := json.Marshal(map[string]any{"path": "/dev/vdb", "name": "Storage1", "format": true})
	r := httptest.NewRequest("POST", "/v1/storage", bytes.NewReader(body))
	r.Header.Set("Authorization", bearer)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)

	if w.Code != http.StatusOK {
		t.Fatalf("status %d: %s", w.Code, w.Body)
	}
	m := decode(t, w)
	if m["success"] != float64(200) {
		t.Fatalf("envelope = %v", m)
	}
	if run.count("mkfs.btrfs") != 1 || run.count("systemctl restart") != 1 {
		t.Fatalf("did not run the expected commands: %v", run.calls)
	}
}

func TestCreateStorageRejectsAPathThatIsNotCurrentlyAvailable(t *testing.T) {
	h, run, bearer := testServerWithCreator(t, "vm-blank-disk.json")
	cases := map[string]string{
		"made up":                       "/dev/does-not-exist",
		"the system disk":               "/dev/vda",
		"mounted (the hot-state disk)":  "/dev/vdc",
		"a partition, not a whole disk": "/dev/vda2",
		"empty":                         "",
	}
	for name, path := range cases {
		body, _ := json.Marshal(map[string]any{"path": path, "format": true})
		r := httptest.NewRequest("POST", "/v1/storage", bytes.NewReader(body))
		r.Header.Set("Authorization", bearer)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code == http.StatusOK {
			t.Errorf("%s (%q): accepted", name, path)
		}
	}
	if run.count("mkfs.btrfs") != 0 || run.count("btrfs device") != 0 {
		t.Fatalf("a rejected request still ran a destructive command: %v", run.calls)
	}
}

func TestCreateStorageRefusesToMountWithoutFormatting(t *testing.T) {
	h, run, bearer := testServerWithCreator(t, "vm-blank-disk.json")
	body, _ := json.Marshal(map[string]any{"path": "/dev/vdb", "format": false})
	r := httptest.NewRequest("POST", "/v1/storage", bytes.NewReader(body))
	r.Header.Set("Authorization", bearer)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusNotImplemented {
		t.Fatalf("status %d: %s", w.Code, w.Body)
	}
	if len(run.calls) != 0 {
		t.Fatalf("format:false still ran commands: %v", run.calls)
	}
}

func TestCreateStorageRejectsAMalformedBody(t *testing.T) {
	h, _, bearer := testServerWithCreator(t, "vm-blank-disk.json")
	r := httptest.NewRequest("POST", "/v1/storage", strings.NewReader("not json"))
	r.Header.Set("Authorization", bearer)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status %d: %s", w.Code, w.Body)
	}
}

func TestCreateStorageRequiresAuthentication(t *testing.T) {
	h, run, _ := testServerWithCreator(t, "vm-blank-disk.json")
	body, _ := json.Marshal(map[string]any{"path": "/dev/vdb", "format": true})
	r := httptest.NewRequest("POST", "/v1/storage", bytes.NewReader(body))
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status %d", w.Code)
	}
	if len(run.calls) != 0 {
		t.Fatalf("an unauthenticated request still ran commands: %v", run.calls)
	}
}

func TestCreateStorageFailurePropagatesWithoutLeakingCommandDetail(t *testing.T) {
	h, run, bearer := testServerWithCreator(t, "vm-blank-disk.json")
	run.errs[key("mkfs.btrfs", "-f", "-L", "recasanix-data", "--", "/dev/vdb")] = errors.New("boom: /dev/vdb: exit status 1")
	body, _ := json.Marshal(map[string]any{"path": "/dev/vdb", "format": true})
	r := httptest.NewRequest("POST", "/v1/storage", bytes.NewReader(body))
	r.Header.Set("Authorization", bearer)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status %d: %s", w.Code, w.Body)
	}
	if strings.Contains(w.Body.String(), "boom") || strings.Contains(w.Body.String(), "exit status") {
		t.Fatalf("leaked command detail: %s", w.Body)
	}
}

func TestCreateStorageOnceUsedIsNoLongerAvailable(t *testing.T) {
	// A disk already part of the pool must not be offered again — re-running create must not silently
	// re-format a live pool member.
	h, run, bearer := testServerWithCreator(t, "image-with-pool.json") // "sda" already carries the pool
	body, _ := json.Marshal(map[string]any{"path": "/dev/sda", "format": true})
	r := httptest.NewRequest("POST", "/v1/storage", bytes.NewReader(body))
	r.Header.Set("Authorization", bearer)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code == http.StatusOK {
		t.Fatalf("a disk already in the pool was accepted for creation again")
	}
	if run.count("mkfs.btrfs") != 0 {
		t.Fatal("a live pool member was reformatted")
	}
}

func TestFormatBytes(t *testing.T) {
	cases := map[uint64]string{
		0:             "0 B",
		1023:          "1023 B",
		1024:          "1.0 KiB",
		1 << 30:       "1.0 GiB",
		3 * (1 << 30): "3.0 GiB",
	}
	for n, want := range cases {
		if got := formatBytes(n); got != want {
			t.Errorf("formatBytes(%d) = %q, want %q", n, got, want)
		}
	}
}
