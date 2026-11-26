# 运行镜像：需先构建 Flutter Web（CI 的 Docker Image 工作流会自动执行 flutter build web --release）
FROM golang:1.26-alpine AS build
WORKDIR /src/server
COPY server/go.mod server/go.sum ./
RUN go mod download
COPY server/ ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/dinglin ./cmd/dinglin

FROM alpine:3.22
RUN apk add --no-cache ca-certificates tzdata \
 && adduser -D -u 10001 -h /app dinglin \
 && mkdir -p /data && chown dinglin:dinglin /data

WORKDIR /app
COPY --from=build /out/dinglin /app/dinglin
COPY client/build/web /app/web

ENV DINGLIN_ADDR=:8080 \
    DINGLIN_DB_PATH=/data/dinglin.db \
    DINGLIN_WEB_DIST_DIR=/app/web

USER dinglin
EXPOSE 8080
VOLUME ["/data"]
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s \
  CMD wget -q -O- http://127.0.0.1:8080/healthz >/dev/null || exit 1
ENTRYPOINT ["/app/dinglin", "serve"]
