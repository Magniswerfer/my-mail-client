# tidings-server (ADR 0007). Build from the repository root, since it needs ../MailEngine:
#   docker build -f PushServer/Dockerfile -t tidings-server .
FROM swift:6.2-noble AS build
RUN apt-get update -qq && apt-get install -y -qq libsqlite3-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY MailEngine MailEngine
COPY PushServer PushServer
RUN swift build -c release --package-path PushServer --product tidings-server --static-swift-stdlib \
    && mkdir /out && cp "$(swift build -c release --package-path PushServer --show-bin-path)/tidings-server" /out/

FROM ubuntu:noble
RUN apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends libsqlite3-0 libcurl4 libxml2 ca-certificates tzdata curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --home-dir /data tidings \
    && mkdir -p /data && chown tidings /data
COPY --from=build /out/tidings-server /usr/local/bin/tidings-server
USER tidings
ENV TIDINGS_DATA_DIR=/data PORT=8080
VOLUME /data
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s CMD curl -fsS http://127.0.0.1:8080/health || exit 1
ENTRYPOINT ["/usr/local/bin/tidings-server"]
