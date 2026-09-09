# Compliance API (D) + dashboard (E) + reports (F).
# Slim Debian base (pdfkit + bcryptjs need no native toolchain, but slim
# avoids alpine's musl edge cases). Runs as non-root.
FROM node:20-slim

WORKDIR /srv

# Deps first (cached layer) — production only.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

# App code (config via environment / .env at runtime, never baked in).
COPY server.js seed.js ./
COPY src/ ./src/
COPY public/ ./public/
RUN mkdir -p uploads && chown -R node:node /srv

USER node
EXPOSE 5000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD node -e "fetch('http://localhost:5000/').then(r=>{process.exit(r.ok?0:1)}).catch(()=>process.exit(1))"

CMD ["node", "server.js"]
