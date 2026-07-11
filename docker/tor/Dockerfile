FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y tor obfs4proxy gosu bash && \
    rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
