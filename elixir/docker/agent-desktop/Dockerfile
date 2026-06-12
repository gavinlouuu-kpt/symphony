FROM node:20-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    fonts-dejavu-core \
    git \
    novnc \
    openbox \
    procps \
    python3 \
    ripgrep \
    websockify \
    x11-utils \
    x11vnc \
    xterm \
    xvfb \
  && rm -rf /var/lib/apt/lists/*

RUN npm install --global @openai/codex
RUN mkdir -p /root/.codex
RUN git config --system --add safe.directory /workspace

COPY desktop_entrypoint.sh /usr/local/bin/symphony-agent-desktop
RUN chmod 755 /usr/local/bin/symphony-agent-desktop

ENV DISPLAY=:1
WORKDIR /workspace
EXPOSE 6080

ENTRYPOINT ["/usr/local/bin/symphony-agent-desktop"]
