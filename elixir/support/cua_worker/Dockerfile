FROM trycua/cua-xfce:latest

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    gnupg \
    openssh-server \
    ripgrep \
  && rm -rf /var/lib/apt/lists/*

RUN install -d -m 755 /etc/apt/keyrings \
  && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
  && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list \
  && apt-get update && apt-get install -y --no-install-recommends nodejs \
  && rm -rf /var/lib/apt/lists/*

RUN install -d -m 755 /var/run/sshd /run/symphony/ssh /run/symphony/codex \
  && install -d -m 700 -o cua -g cua /home/cua/.ssh /home/cua/.codex

RUN npm install --global @openai/codex@0.136.0

COPY symphony-sshd-start.sh /usr/local/bin/symphony-sshd-start
COPY symphony-sshd.conf /etc/supervisor/conf.d/symphony-sshd.conf

RUN chmod 755 /usr/local/bin/symphony-sshd-start

EXPOSE 22 5901 6901 8000
