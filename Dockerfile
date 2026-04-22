# syntax=docker/dockerfile:1
#
# docker build -t vector-probes .
# docker run --rm -it --privileged --pid=host vector-probes
#
FROM rust:1.92-bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates cmake protobuf-compiler libprotobuf-dev g++ libssl-dev pkg-config git \
    && rm -rf /var/lib/apt/lists/*

# If behind an SSL-inspecting proxy, uncomment and provide your CA bundle:
# COPY corp-ca-bundle.pem /usr/local/share/ca-certificates/corp.crt
# RUN update-ca-certificates

# Clone from the fork where the component-probes branch lives.
# Once the PR (vectordotdev/vector#24860) is merged, change to master.
ARG CACHEBUST=0
RUN echo "$CACHEBUST" && git clone --depth 1 --branch component-probes \
    https://github.com/connoryy/vector.git /vector \
    || { echo ""; echo "ERROR: git clone failed."; \
         echo "If behind an SSL proxy, uncomment the COPY/RUN ca-certificate lines in the Dockerfile"; \
         echo "and place your CA bundle at corp-ca-bundle.pem next to the Dockerfile."; \
         exit 1; }

WORKDIR /vector
ENV CARGO_PROFILE_RELEASE_DEBUG=line-tables-only
RUN cargo build --release --no-default-features \
    --features "sources-demo_logs,sinks-blackhole,transforms-remap,component-probes"

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    bpftrace && rm -rf /var/lib/apt/lists/*
COPY --from=builder /vector/target/release/vector /usr/local/bin/vector
RUN mkdir -p /etc/vector
COPY vector.yaml /etc/vector/vector.yaml
COPY probe.bt /opt/probe.bt
COPY run.sh /opt/run.sh
RUN chmod +x /opt/run.sh

ENTRYPOINT ["/opt/run.sh"]
