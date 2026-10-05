# Match .mise.toml. Pin the multi-platform manifest as well as the readable tag.
FROM hexpm/elixir:1.20.4-erlang-29.0.6-ubuntu-noble-20260917@sha256:281aac40735e8f86131f6f01fbbf147108aac5509d1fce32ef899ab0b672e854

ARG TARGETARCH
ENV DEBIAN_FRONTEND=noninteractive \
    MIX_ENV=test \
    MIX_HOME=/opt/mix \
    HEX_HOME=/opt/hex \
    ERL_FLAGS="+S 2:2 +SDcpu 1 +SDio 1 +JMsingle true" \
    STILL_STRICT_INTEGRATION=1 \
    LANG=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential git curl ca-certificates tar gzip unzip \
      systemd systemd-sysv dbus procps iproute2 util-linux \
      libstdc++6 libncurses6 libtinfo6 libssl3 libsctp1 bats shellcheck \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# SHA-512 values published with the Caddy 2.11.2 release (also used by CI).
RUN case "$TARGETARCH" in \
      amd64) checksum=2513b289054386b76642a9e8bfc10d217df2b5361e4cdd0c72672b0eeab57ae737d57466eb70f1a44233cbcc697ecf21de88137ca45ef4b64f150a32b58f5f14 ;; \
      arm64) checksum=630d1e096e3c9594fd2f4f7129356ee5d6c7e53d0ca1b9a0c7486612c6d752ff355c96738c7a28c60367a5f1da4b51afca731bb745fb0b97cda4c811214cdc48 ;; \
      *) exit 1 ;; \
    esac \
    && curl --fail --show-error --location --retry 3 \
      "https://github.com/caddyserver/caddy/releases/download/v2.11.2/caddy_2.11.2_linux_${TARGETARCH}.tar.gz" -o /tmp/caddy.tar.gz \
    && printf '%s  %s\n' "$checksum" /tmp/caddy.tar.gz | sha512sum --check --strict \
    && tar -xzf /tmp/caddy.tar.gz -C /usr/local/bin caddy \
    && rm /tmp/caddy.tar.gz \
    && caddy version

RUN useradd --create-home --uid 10001 tester \
    && mkdir -p /workspace /opt/mix /opt/hex /opt/still-fixtures \
    && chown -R tester:tester /workspace /opt/mix /opt/hex /opt/still-fixtures \
    && systemctl set-default multi-user.target

WORKDIR /workspace
USER tester
COPY --chown=tester:tester mix.exs mix.lock ./
RUN mix local.hex --force && mix local.rebar --force \
    && mix deps.get && mix deps.compile
COPY infra/test/build-fixtures.sh /usr/local/bin/still-build-fixtures
RUN bash /usr/local/bin/still-build-fixtures
COPY --chown=tester:tester . .
RUN mix compile --warnings-as-errors

USER root
RUN install -m 0755 infra/test/run-suite.sh /usr/local/bin/still-test-suite
ENV container=docker SHELL=/bin/bash STILL_RELEASE_FIXTURES_DIR=/opt/still-fixtures
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
