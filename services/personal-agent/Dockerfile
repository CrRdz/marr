FROM node:22-bookworm-slim
ARG CODEX_VERSION=0.146.0
RUN apt-get update && apt-get install -y --no-install-recommends python3 ca-certificates git tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g @openai/codex@${CODEX_VERSION}
RUN mkdir -p /data/codex /app && chown -R node:node /data /app
WORKDIR /app
COPY state.py executor.py server.py ./
USER node
ENV CODEX_HOME=/data/codex MARR_AGENT_DATA=/data MARR_AGENT_BIND=0.0.0.0
EXPOSE 8787
HEALTHCHECK --interval=30s CMD python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:8787/health', timeout=3)"
CMD ["python3", "server.py"]
