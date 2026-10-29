package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"slices"
	"strings"
)

// The storage layer's API (docs/storage-layer.md): backend-neutral, the v2 envelope ({message, data}).
//
//	GET  /v2/storage                       pool (or null), drives with roles and verbs, layouts, jobs
//	GET  /v2/storage/layouts?disks=a,b     what each layout gives on those free disks
//	POST /v2/storage/plans                 Intent → Plan (preview), or 409 with the reason
//	POST /v2/storage/plans/{id}/apply      {confirm} → Job (202); 409 stale / busy, 400 confirmation
//	GET  /v2/storage/jobs                  recent jobs

type layoutOption struct {
	Layout      Layout `json:"layout"`
	Backend     string `json:"backend"`
	Profile     string `json:"profile"`
	Description string `json:"description"`
	Capacity    uint64 `json:"capacity"`
	Tolerates   int    `json:"tolerates"`
	MinDisks    int    `json:"min_disks"`
	Possible    bool   `json:"possible"`
	Reason      string `json:"reason,omitempty"`
}

func layoutOptions(ds []StorageDrive) []layoutOption {
	var out []layoutOption
	for _, l := range layouts {
		o := layoutOption{Layout: l, Backend: l.Backend(), Profile: l.Profile(), Description: l.String(),
			Tolerates: l.Tolerates(), MinDisks: l.MinDisks(), Capacity: l.Capacity(sizes(ds)), Possible: len(ds) >= l.MinDisks()}
		if !o.Possible {
			o.Reason = "needs at least " + diskCount(l.MinDisks())
		}
		out = append(out, o)
	}
	return out
}

func (a *API) storageOverview(w http.ResponseWriter, r *http.Request) {
	v, err := a.inv.view(r.Context())
	if err != nil {
		a.internalError(w, "storage view", err)
		return
	}
	drives := v.drives
	if drives == nil {
		drives = []StorageDrive{}
	}
	writeJSON(w, http.StatusOK, v2Envelope{Message: "ok", Data: map[string]any{
		"pool": v.pool, "drives": drives, "layouts": layoutOptions(v.free()), "jobs": a.planner.Jobs(), "busy": a.planner.Busy(),
	}})
}

func (a *API) storageLayouts(w http.ResponseWriter, r *http.Request) {
	v, err := a.inv.view(r.Context())
	if err != nil {
		a.internalError(w, "storage view", err)
		return
	}
	var chosen []StorageDrive
	for _, name := range strings.Split(r.URL.Query().Get("disks"), ",") {
		if d := v.drive(strings.TrimSpace(name)); d != nil && d.Role == "free" &&
			!slices.ContainsFunc(chosen, func(c StorageDrive) bool { return c.Name == d.Name }) {
			chosen = append(chosen, *d)
		}
	}
	writeJSON(w, http.StatusOK, v2Envelope{Message: "ok", Data: layoutOptions(chosen)})
}

const maxIntentBody = 4 << 10

func (a *API) storagePlan(w http.ResponseWriter, r *http.Request) {
	var in Intent
	r.Body = http.MaxBytesReader(w, r.Body, maxIntentBody)
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil || in.Verb == "" {
		writeJSON(w, http.StatusBadRequest, v2Envelope{Message: "invalid request body"})
		return
	}
	plan, err := a.planner.Plan(r.Context(), in)
	if err != nil {
		a.planError(w, "plan", err)
		return
	}
	writeJSON(w, http.StatusOK, v2Envelope{Message: "ok", Data: plan})
}

func (a *API) storageApply(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Confirm string `json:"confirm"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxIntentBody)
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, v2Envelope{Message: "invalid request body"})
		return
	}
	job, err := a.planner.Apply(r.Context(), r.PathValue("id"), body.Confirm)
	if err != nil {
		a.planError(w, "apply", err)
		return
	}
	writeJSON(w, http.StatusAccepted, v2Envelope{Message: "ok", Data: job})
}

func (a *API) storageJobs(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, v2Envelope{Message: "ok", Data: a.planner.Jobs()})
}

// planError: a refusal says why (409, or 400 for a wrong confirmation), a missing plan is 404, the
// rest is logged and kept vague.
func (a *API) planError(w http.ResponseWriter, what string, err error) {
	var r refusal
	switch {
	case errors.Is(err, errNoPlan):
		writeJSON(w, http.StatusNotFound, v2Envelope{Message: err.Error()})
	case errors.Is(err, errConfirm):
		writeJSON(w, http.StatusBadRequest, v2Envelope{Message: err.Error()})
	case errors.As(err, &r):
		writeJSON(w, http.StatusConflict, v2Envelope{Message: r.msg})
	default:
		a.internalError(w, what, err)
	}
}
