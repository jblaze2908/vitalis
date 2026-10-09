# Vitalis: one Node process (Hono + MCP SDK + node:sqlite). The SQLite file lives under /srv/vitalis, mounted from the host.
FROM node:22-bookworm-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts --no-audit --no-fund
COPY tsconfig.json ./
COPY src ./src
COPY data ./data
COPY tests ./tests
RUN npm run build && npm test && npm prune --omit=dev

FROM node:22-bookworm-slim
WORKDIR /app
ENV NODE_ENV=production VITALIS_ROOT=/srv/vitalis VITALIS_BIND=0.0.0.0 PORT=8350 NODE_OPTIONS=--no-warnings=ExperimentalWarning
COPY --from=build /app/package.json ./
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY --from=build /app/data ./data
USER 1650:1650
EXPOSE 8350
HEALTHCHECK --interval=30s --timeout=3s CMD node -e "fetch('http://127.0.0.1:8350/health').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"
CMD ["node", "dist/src/server.js"]
