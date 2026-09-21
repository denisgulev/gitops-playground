package main

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
)

func testLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func TestHelloEndpoint(t *testing.T) {
	r := newRouter(testLogger(), newRateLimiterStore(), "eu-south-1", "https://static.example.com", "test")

	req := httptest.NewRequest(http.MethodGet, "/api/hello", nil)
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", rec.Code)
	}

	var body map[string]string
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatalf("failed to decode response body: %v", err)
	}
	if body["message"] != "Hello from Go!" {
		t.Errorf("unexpected message: %q", body["message"])
	}
}

func TestStatusEndpoint(t *testing.T) {
	r := newRouter(testLogger(), newRateLimiterStore(), "eu-south-1", "https://static.example.com", "v1.2.3")

	req := httptest.NewRequest(http.MethodGet, "/api/status", nil)
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", rec.Code)
	}

	var body map[string]string
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatalf("failed to decode response body: %v", err)
	}

	want := map[string]string{
		"status":      "ok",
		"version":     "v1.2.3",
		"region":      "eu-south-1",
		"static_site": "https://static.example.com",
	}
	for k, v := range want {
		if body[k] != v {
			t.Errorf("field %q: expected %q, got %q", k, v, body[k])
		}
	}
}

func TestNotFoundRedirectsToStaticSite(t *testing.T) {
	staticURL := "https://static.example.com"
	r := newRouter(testLogger(), newRateLimiterStore(), "eu-south-1", staticURL, "test")

	req := httptest.NewRequest(http.MethodGet, "/no-such-route", nil)
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusFound {
		t.Fatalf("expected status 302, got %d", rec.Code)
	}
	if got := rec.Header().Get("Location"); got != staticURL+"/error.html" {
		t.Errorf("unexpected redirect location: %q", got)
	}
}

func TestRateLimiterStoreAllowsBurstThenBlocks(t *testing.T) {
	store := newRateLimiterStore()

	allowed := 0
	for i := 0; i < 60; i++ {
		if store.allow("1.2.3.4") {
			allowed++
		}
	}

	// The hourly limiter has a burst of 50 — the first 50 calls should be
	// allowed immediately, further calls in the same instant should not.
	if allowed != 50 {
		t.Errorf("expected 50 requests to be allowed before throttling, got %d", allowed)
	}

	// A different IP has its own independent budget.
	if !store.allow("5.6.7.8") {
		t.Error("expected a fresh IP to be allowed")
	}
}

func TestRateLimitMiddlewareReturns429WhenExceeded(t *testing.T) {
	store := newRateLimiterStore()
	handler := rateLimitMiddleware(store)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))

	var lastCode int
	for i := 0; i < 51; i++ {
		req := httptest.NewRequest(http.MethodGet, "/api/hello", nil)
		req.RemoteAddr = "9.9.9.9:1234"
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		lastCode = rec.Code
	}

	if lastCode != http.StatusTooManyRequests {
		t.Errorf("expected the 51st request to be throttled with 429, got %d", lastCode)
	}
}
