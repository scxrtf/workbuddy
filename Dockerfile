# syntax=docker/dockerfile:1
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY . .
# 一次编译全部二进制（工具进镜像，容器内可直接跑脚本）。全部 -trimpath -s -w。
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/wb2api ./cmd/server \
 && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/signin_bin ./cmd/signin \
 && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/login ./cmd/login \
 && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/credit ./cmd/credit

FROM alpine:3.20
# python3：login.sh 的 JSON 解析 / 签到 / 落盘；bash：shell 脚本体。
RUN apk add --no-cache wget ca-certificates tzdata python3 bash \
 && adduser -D -u 10001 app \
 && mkdir -p /app/auths /app/data \
 && chown -R app:app /app
WORKDIR /app
# 脚本置入 + 去 CRLF（Windows 检出可能性）在切到 app 之前以 root 完成——
# app 对 root 所有文件无写权限，sed -i 需要写权限。
COPY --from=build /out/wb2api /app/wb2api
COPY --from=build /out/signin_bin /app/signin_bin
COPY --from=build /out/login /app/login
COPY --from=build /out/credit /app/credit
COPY login.sh signin.sh credit.sh /app/
COPY scripts/probe_active.py /app/scripts/probe_active.py
RUN sed -i 's/\r$//' /app/login.sh /app/signin.sh /app/credit.sh && chmod 755 /app/login.sh /app/signin.sh /app/credit.sh
# 镜像刻意不带 config.json：首次启动由 wb2api 自动生成（含随机 api_key 与 0600 权限），
# 这样既不会把样例里的 test_key 带进生产，又保证 app 用户对配置可写（面板保存配置需要）。
# 需要固定密钥时用 WB2A_API_KEY / WB2A_API_KEYS 环境变量注入。
# auth_dir/state_file 保持默认相对路径（WORKDIR=/app → /app/auths、/app/data/state.json），
# 不用 ENV 写死，挂载的 config.json 才能改这两个路径。
USER app
# 平台（Railway 等）注入的 PORT 优先；本地 compose 未设时回落 7863。
ENV PORT=7863
EXPOSE ${PORT}
# shell 形式以便在运行时展开 PORT（exec 形式不做变量替换）。
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s \
  CMD wget -qO- http://127.0.0.1:${PORT:-7863}/healthz || exit 1
ENTRYPOINT ["/app/wb2api", "-config", "/app/config.json"]
