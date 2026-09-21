# ── Build stage ───────────────────────────────────────────────────────────────
# The build stage always runs on the machine doing the build ($BUILDPLATFORM) and
# Go cross-compiles for the target, so no CPU emulation is needed to produce an
# arm64 image on an amd64 CI runner.
FROM --platform=$BUILDPLATFORM golang:1.27.0-alpine AS builder

# Set by BuildKit from --platform. The defaults keep the previous behaviour
# (linux/arm64, the EC2 architecture) for builders that do not set them.
ARG TARGETOS=linux
ARG TARGETARCH=arm64

WORKDIR /build
COPY go.mod go.sum ./
RUN go mod download

COPY main.go .
# CGO_ENABLED=0 produces a fully static binary — no libc dependency
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -ldflags="-s -w" -o app .

# ── Runtime stage ─────────────────────────────────────────────────────────────
FROM scratch

COPY --from=builder /build/app /app
# Copy TLS certs so HTTPS calls to CloudWatch work
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

# Run as an unprivileged user. A numeric id is used because scratch has no
# /etc/passwd; the app only listens on 8000 and writes nothing to disk.
USER 65532:65532

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD ["/app", "-healthcheck"]

ENTRYPOINT ["/app"]
