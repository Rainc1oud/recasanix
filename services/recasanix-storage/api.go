package main

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
)

// The routes below are the ones the web UI already calls (they were CasaOS-LocalStorage's), answered
// with the same shapes, so the UI needs no change. Creating a new storage on a blank disk works
// (Creator); everything else that would change storage — formatting or removing an *existing* one,
// merging, mounting something without formatting it — is refused with a message that says so.

// routePaths are registered with the gateway; the gateway forwards everything below them.
var routePaths = []string{"/v1/disks", "/v1/storage", "/v2/local_storage"}

const (
	unsupportedChangeMessage = "Formatting or removing an existing storage, and merging storages, are not " +
		"available yet. Create a new storage on a blank disk instead."
	mountOnlyNotSupportedMessage = "Using an existing filesystem without formatting it is not supported yet; " +
		"only creating a new formatted storage on a blank disk is."
)

// envelope is the v1 response format of the CasaOS services.
type envelope struct {
	Success int    `json:"success"`
	Message string `json:"message"`
	Data    any    `json:"data,omitempty"`
}

// v2Envelope is the v2 format: a message and the data, no status field.
type v2Envelope struct {
	Message string `json:"message"`
	Data    any    `json:"data"`
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// API serves the storage endpoints.
type API struct {
	inv     *Inventory
	creator *Creator
	log     *slog.Logger
}

// Handler returns the routes, without authentication (see Authenticator.Middleware).
func (a *API) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/disks", a.disks)
	mux.HandleFunc("GET /v1/disks/usb", a.usb)
	mux.HandleFunc("GET /v1/storage", a.storage)
	mux.HandleFunc("POST /v1/storage", a.createStorage)
	mux.HandleFunc("GET /v2/local_storage/merge", a.merge)

	// Anything else below these prefixes: a change is refused, an unknown read is not found.
	for _, p := range routePaths {
		mux.HandleFunc(p, a.otherwise)
		mux.HandleFunc(p+"/", a.otherwise)
	}
	return noStore(mux)
}

// noStore keeps proxies and browsers from caching inventory or error responses.
func noStore(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		next.ServeHTTP(w, r)
	})
}

func (a *API) disks(w http.ResponseWriter, r *http.Request) {
	disks, avail, err := a.inv.Disks(r.Context())
	if err != nil {
		a.internalError(w, "list disks", err)
		return
	}
	writeJSON(w, http.StatusOK, envelope{
		Success: http.StatusOK, Message: "ok",
		Data: map[string]any{"disks": disks, "avail": avail},
	})
}

func (a *API) storage(w http.ResponseWriter, r *http.Request) {
	list, err := a.inv.Storage(r.Context(), r.URL.Query().Get("system") != "")
	if err != nil {
		a.internalError(w, "list storage", err)
		return
	}
	writeJSON(w, http.StatusOK, envelope{Success: http.StatusOK, Message: "ok", Data: list})
}

// createStorageRequest is the body the UI sends — `{path, name, format}`. `name` is accepted and
// ignored: there is one pool, under its own fixed label, not a user-chosen one per disk.
type createStorageRequest struct {
	Path   string `json:"path"`
	Format bool   `json:"format"`
}

const maxCreateStorageBody = 4 << 10

func (a *API) createStorage(w http.ResponseWriter, r *http.Request) {
	var req createStorageRequest
	r.Body = http.MaxBytesReader(w, r.Body, maxCreateStorageBody)
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, envelope{Success: http.StatusBadRequest, Message: "invalid request body"})
		return
	}
	if !req.Format {
		writeJSON(w, http.StatusNotImplemented, envelope{Success: http.StatusNotImplemented, Message: mountOnlyNotSupportedMessage})
		return
	}
	if req.Path == "" {
		writeJSON(w, http.StatusBadRequest, envelope{Success: http.StatusBadRequest, Message: "path is required"})
		return
	}

	// Trust nothing from the request except which currently-available disk to use: re-derive the
	// eligible set fresh, right now, and accept only an exact match. A path that does not match — made
	// up, a partition, in use, the system disk, too small, or simply stale from an earlier GET — is
	// refused before anything runs, not discovered as a command failure.
	_, avail, err := a.inv.Disks(r.Context())
	if err != nil {
		a.internalError(w, "list disks", err)
		return
	}
	eligible := false
	for _, d := range avail {
		if d.Path == req.Path {
			eligible = true
			break
		}
	}
	if !eligible {
		writeJSON(w, http.StatusConflict, envelope{
			Success: http.StatusConflict,
			Message: fmt.Sprintf("%s is not an available disk: it must be blank, unused and at least %s",
				req.Path, formatBytes(a.inv.cfg.MinDiskSize)),
		})
		return
	}

	if err := a.creator.Create(r.Context(), req.Path); err != nil {
		a.log.Error("create storage", "path", req.Path, "error", err)
		writeJSON(w, http.StatusInternalServerError, envelope{
			Success: http.StatusInternalServerError,
			Message: fmt.Sprintf("could not create storage on %s", req.Path),
		})
		return
	}
	writeJSON(w, http.StatusOK, envelope{Success: http.StatusOK, Message: "ok"})
}

// formatBytes is the small human-readable rendering used in the one message above, not a general
// display routine.
func formatBytes(n uint64) string {
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%d B", n)
	}
	div, exp := uint64(unit), 0
	for n/div >= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %ciB", float64(n)/float64(div), "KMGTPE"[exp])
}

// usb: removable media is not supported yet (it comes back as native units, not scripts), so there is
// nothing to list.
func (a *API) usb(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, envelope{Success: http.StatusOK, Message: "ok", Data: []any{}})
}

// merge: there is no merged storage here. An empty list is the correct answer, not a stub for a
// missing feature: the UI treats it as "nothing is merged".
func (a *API) merge(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, v2Envelope{Message: "ok", Data: []any{}})
}

func (a *API) otherwise(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet || r.Method == http.MethodHead {
		writeJSON(w, http.StatusNotFound, envelope{Success: http.StatusNotFound, Message: "not found"})
		return
	}
	writeJSON(w, http.StatusNotImplemented, envelope{Success: http.StatusNotImplemented, Message: unsupportedChangeMessage})
}

// internalError logs the cause and tells the caller as little as possible.
func (a *API) internalError(w http.ResponseWriter, what string, err error) {
	a.log.Error(what, "error", err)
	writeJSON(w, http.StatusInternalServerError, envelope{Success: http.StatusInternalServerError, Message: "could not read the block devices"})
}
