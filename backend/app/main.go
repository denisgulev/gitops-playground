package main

import (
    "context"
    "encoding/json"
    "fmt"
    "log/slog"
    "net/http"
    "os"
    "sync"
    "time"

    "github.com/aws/aws-sdk-go-v2/aws"
    "github.com/aws/aws-sdk-go-v2/config"
    "github.com/aws/aws-sdk-go-v2/service/cloudwatchlogs"
    "github.com/aws/aws-sdk-go-v2/service/cloudwatchlogs/types"
    "github.com/go-chi/chi/v5"
    "github.com/go-chi/chi/v5/middleware"
    "golang.org/x/time/rate"
)

// ── CloudWatch log handler ────────────────────────────────────────────────────

type cwHandler struct {
    client    *cloudwatchlogs.Client
    logGroup  string
    logStream string
    mu        sync.Mutex
    buf       []types.InputLogEvent
    next      slog.Handler
}

func newCWHandler(ctx context.Context, region, logGroup string, next slog.Handler) (*cwHandler, error) {
    cfg, err := config.LoadDefaultConfig(ctx, config.WithRegion(region))
    if err != nil {
        return nil, err
    }
    client := cloudwatchlogs.NewFromConfig(cfg)
    stream := fmt.Sprintf("go-app-%d", time.Now().Unix())

    // Ensure log group exists
    _, _ = client.CreateLogGroup(ctx, &cloudwatchlogs.CreateLogGroupInput{
        LogGroupName: aws.String(logGroup),
    })
    _, _ = client.CreateLogStream(ctx, &cloudwatchlogs.CreateLogStreamInput{
        LogGroupName:  aws.String(logGroup),
        LogStreamName: aws.String(stream),
    })

    h := &cwHandler{client: client, logGroup: logGroup, logStream: stream, next: next}
    go h.flushLoop(ctx)
    return h, nil
}

func (h *cwHandler) Enabled(ctx context.Context, level slog.Level) bool {
    return h.next.Enabled(ctx, level)
}

func (h *cwHandler) Handle(ctx context.Context, r slog.Record) error {
    msg := fmt.Sprintf("[%s] %s", r.Level, r.Message)
    ts := r.Time.UnixMilli()
    h.mu.Lock()
    h.buf = append(h.buf, types.InputLogEvent{Message: aws.String(msg), Timestamp: aws.Int64(ts)})
    h.mu.Unlock()
    return h.next.Handle(ctx, r)
}

func (h *cwHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
    return &cwHandler{client: h.client, logGroup: h.logGroup, logStream: h.logStream, next: h.next.WithAttrs(attrs)}
}

func (h *cwHandler) WithGroup(name string) slog.Handler {
    return &cwHandler{client: h.client, logGroup: h.logGroup, logStream: h.logStream, next: h.next.WithGroup(name)}
}

func (h *cwHandler) flushLoop(ctx context.Context) {
    ticker := time.NewTicker(5 * time.Second)
    defer ticker.Stop()
    for {
        select {
        case <-ctx.Done():
            h.flush(ctx)
            return
        case <-ticker.C:
            h.flush(ctx)
        }
    }
}

func (h *cwHandler) flush(ctx context.Context) {
    h.mu.Lock()
    if len(h.buf) == 0 {
        h.mu.Unlock()
        return
    }
    events := h.buf
    h.buf = nil
    h.mu.Unlock()

    _, _ = h.client.PutLogEvents(ctx, &cloudwatchlogs.PutLogEventsInput{
        LogGroupName:  aws.String(h.logGroup),
        LogStreamName: aws.String(h.logStream),
        LogEvents:     events,
    })
}

// ── Per-IP rate limiter ───────────────────────────────────────────────────────

type ipLimiter struct {
    hourly *rate.Limiter // 50/hour
    daily  *rate.Limiter // 200/day
}

type rateLimiterStore struct {
    mu       sync.Mutex
    limiters map[string]*ipLimiter
}

func newRateLimiterStore() *rateLimiterStore {
    s := &rateLimiterStore{limiters: make(map[string]*ipLimiter)}
    go s.cleanupLoop()
    return s
}

func (s *rateLimiterStore) get(ip string) *ipLimiter {
    s.mu.Lock()
    defer s.mu.Unlock()
    if lim, ok := s.limiters[ip]; ok {
        return lim
    }
    lim := &ipLimiter{
        hourly: rate.NewLimiter(rate.Every(72*time.Second), 50),  // 50/hour
        daily:  rate.NewLimiter(rate.Every(432*time.Second), 200), // 200/day
    }
    s.limiters[ip] = lim
    return lim
}

func (s *rateLimiterStore) allow(ip string) bool {
    lim := s.get(ip)
    return lim.hourly.Allow() && lim.daily.Allow()
}

// Periodically evict stale entries to prevent unbounded growth
func (s *rateLimiterStore) cleanupLoop() {
    ticker := time.NewTicker(10 * time.Minute)
    defer ticker.Stop()
    for range ticker.C {
        s.mu.Lock()
        s.limiters = make(map[string]*ipLimiter)
        s.mu.Unlock()
    }
}

// ── Middleware ────────────────────────────────────────────────────────────────

func rateLimitMiddleware(store *rateLimiterStore) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            ip := r.RemoteAddr
            if !store.allow(ip) {
                http.Error(w, "rate limit exceeded", http.StatusTooManyRequests)
                return
            }
            next.ServeHTTP(w, r)
        })
    }
}

func requestLogger(logger *slog.Logger) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            logger.Info("request", "method", r.Method, "path", r.URL.Path, "remote", r.RemoteAddr)
            next.ServeHTTP(w, r)
        })
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

func writeJSON(w http.ResponseWriter, status int, v any) {
    w.Header().Set("Content-Type", "application/json")
    w.WriteHeader(status)
    _ = json.NewEncoder(w).Encode(v)
}

// ── Main ──────────────────────────────────────────────────────────────────────

func main() {
    ctx := context.Background()

    awsRegion  := envOr("AWS_REGION", "eu-south-1")
    logGroup   := envOr("CLOUDWATCH_LOG_GROUP", "go-app-logs")
    staticURL  := envOr("STATIC_SITE_URL", "https://static-website.example.com")
    appVersion := envOr("APP_VERSION", "unknown")

    // Base logger (stdout — captured by Docker, shipped by Promtail)
    baseHandler := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})
    var handler slog.Handler = baseHandler

    // Wrap with CloudWatch handler if available
    cwh, err := newCWHandler(ctx, awsRegion, logGroup, baseHandler)
    if err != nil {
        slog.New(baseHandler).Warn("could not initialize CloudWatch handler", "error", err)
    } else {
        handler = cwh
    }

    logger := slog.New(handler)
    logger.Info("logging to stdout + CloudWatch is active")

    store := newRateLimiterStore()

    r := chi.NewRouter()
    r.Use(middleware.Recoverer)
    r.Use(requestLogger(logger))
    r.Use(rateLimitMiddleware(store))

    r.Get("/api/hello", func(w http.ResponseWriter, r *http.Request) {
        logger.Info("GET /api/hello called")
        writeJSON(w, http.StatusOK, map[string]string{"message": "Hello from Go!"})
    })

    r.Get("/api/info", func(w http.ResponseWriter, r *http.Request) {
        logger.Info("GET /api/info called")
        writeJSON(w, http.StatusOK, map[string]string{"info": "This is a simple info endpoint."})
    })

    r.Get("/api/status", func(w http.ResponseWriter, r *http.Request) {
        logger.Info("GET /api/status called")
        writeJSON(w, http.StatusOK, map[string]string{
            "status":      "ok",
            "version":     appVersion,
            "region":      awsRegion,
            "static_site": staticURL,
        })
    })

    r.Get("/api/about", func(w http.ResponseWriter, r *http.Request) {
        logger.Info("GET /api/about called")
        writeJSON(w, http.StatusOK, map[string]any{
            "project":     "GitOps Playground",
            "description": "Go API on EC2, static frontend on S3, served via CloudFront. Fully automated with Terraform and GitHub Actions.",
            "stack": map[string]any{
                "frontend":        []string{"S3", "CloudFront", "Route 53", "ACM"},
                "backend":         []string{"EC2", "Docker", "Go", "net/http"},
                "infrastructure":  []string{"Terraform", "Terraform Cloud"},
                "ci_cd":           []string{"GitHub Actions"},
                "observability":   []string{"Grafana", "Loki", "Promtail", "Tempo"},
            },
            "source_code": "https://github.com/denisgulev/gitops-playground",
        })
    })

    r.NotFound(func(w http.ResponseWriter, r *http.Request) {
        logger.Warn("404", "path", r.URL.Path)
        http.Redirect(w, r, staticURL+"/error.html", http.StatusFound)
    })

    logger.Info("starting Go app", "port", 8000)
    if err := http.ListenAndServe(":8000", r); err != nil {
        logger.Error("server failed", "error", err)
        os.Exit(1)
    }
}

func envOr(key, fallback string) string {
    if v := os.Getenv(key); v != "" {
        return v
    }
    return fallback
}