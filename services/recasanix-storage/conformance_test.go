package main

import (
	"bytes"
	"context"
	_ "embed"
	"io"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/getkin/kin-openapi/openapi3"
	"github.com/getkin/kin-openapi/openapi3filter"
	"github.com/getkin/kin-openapi/routers/legacy"
)

// The storage layer's contract (CasaOS-LocalStorage#10, api/storage/openapi.yaml): kept here as a copy;
// every /v2/storage answer of this service must fit it.
//
//go:embed openapi/storage.yaml
var storageSpec []byte

func TestV2StorageConformsToTheContract(t *testing.T) {
	doc, err := openapi3.NewLoader().LoadFromData(storageSpec)
	if err != nil {
		t.Fatal(err)
	}
	if err := doc.Validate(context.Background()); err != nil {
		t.Fatalf("spec: %v", err)
	}
	// strict: a field the contract does not name is drift too
	no := false
	for _, ref := range doc.Components.Schemas {
		if ref.Value.Type.Is("object") {
			ref.Value.AdditionalProperties = openapi3.AdditionalProperties{Has: &no}
		}
	}
	doc.Servers = openapi3.Servers{{URL: "http://box/v2/storage"}}
	router, err := legacy.NewRouter(doc)
	if err != nil {
		t.Fatal(err)
	}

	for name, r := range map[string]*rig{
		"no pool":     newRig(t, machine(blank("vdb", 8), blank("vdc", 8))),
		"mirror":      mirrorRig(t),
		"parity":      mdRig(t, true),
		"wipe a disk": newRig(t, machine(`{"name":"vdb","path":"/dev/vdb","type":"disk","size":8589934592,"fstype":"ext4","uuid":"x","mountpoints":[null]}`, blank("vdc", 8))),
	} {
		priv := newKey(t)
		api := &API{inv: r.inv, creator: newCreator(r.run, r.inv.cfg), planner: r.pl, log: discardLog()}
		h := newAuthenticator(staticKey{key: &priv.PublicKey}).Middleware(api.Handler())
		bearer := "Bearer " + token(t, priv, tokenOpts{issuer: "casaos", expires: in(time.Hour)})

		check := func(method, path, body string) []byte {
			t.Helper()
			req := httptest.NewRequest(method, "http://box"+path, bytes.NewBufferString(body))
			req.Header.Set("Authorization", bearer)
			if body != "" {
				req.Header.Set("Content-Type", "application/json")
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, req)

			route, params, err := router.FindRoute(req)
			if err != nil {
				t.Fatalf("%s: %s %s: %v", name, method, path, err)
			}
			req.Body = io.NopCloser(bytes.NewBufferString(body))
			in := &openapi3filter.RequestValidationInput{Request: req, PathParams: params, Route: route,
				Options: &openapi3filter.Options{AuthenticationFunc: openapi3filter.NoopAuthenticationFunc}}
			if err := openapi3filter.ValidateRequest(context.Background(), in); err != nil {
				t.Errorf("%s: request %s %s: %v", name, method, path, err)
			}
			out := &openapi3filter.ResponseValidationInput{RequestValidationInput: in, Status: w.Code, Header: w.Header(),
				Body: io.NopCloser(bytes.NewReader(w.Body.Bytes())), Options: &openapi3filter.Options{IncludeResponseStatus: true}}
			if err := openapi3filter.ValidateResponse(context.Background(), out); err != nil {
				t.Errorf("%s: response %s %s (%d): %v", name, method, path, w.Code, err)
			}
			return w.Body.Bytes()
		}

		check("GET", "/v2/storage", "")
		check("GET", "/v2/storage/layouts?disks=vdb,vdc", "")
		check("GET", "/v2/storage/jobs", "")
		check("POST", "/v2/storage/plans", `{"verb":"check","pool":"nonesuch"}`) // 409
		check("POST", "/v2/storage/plans/nonesuch/apply", `{"confirm":""}`)      // 404
		var intent string
		switch name {
		case "no pool":
			intent = `{"verb":"create-pool","layout":{"kind":"mirror","copies":2},"disks":["vdb","vdc"]}`
		case "mirror":
			intent = `{"verb":"delete-pool","pool":"recasanix-data"}`
		case "parity":
			intent = `{"verb":"replace-disk","pool":"recasanix-data","member":"vdc","disks":["vde"]}`
		case "wipe a disk":
			intent = `{"verb":"wipe-disk","disks":["vdb"]}`
		}
		plan := decode(t, &httptest.ResponseRecorder{Body: bytes.NewBuffer(check("POST", "/v2/storage/plans", intent))})
		data, ok := plan["data"].(map[string]any)
		if !ok {
			t.Fatalf("%s: no plan: %v", name, plan)
		}
		id, confirm := data["id"].(string), data["confirm"].(string)
		check("POST", "/v2/storage/plans/"+id+"/apply", `{"confirm":"wrong"}`) // 400 (or 202 when none asked)
		check("POST", "/v2/storage/plans/"+id+"/apply", `{"confirm":"`+confirm+`"}`)
		for range 200 {
			if !r.pl.Busy() {
				break
			}
			time.Sleep(5 * time.Millisecond)
		}
		check("GET", "/v2/storage/jobs", "")
	}
}
