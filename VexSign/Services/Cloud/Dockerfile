# Node 22 is the LTS line CI tests (services.yml `node-version: '22'`) and that
# `@types/node` is pinned to. The base image was the odd-numbered Current release 25:
# those never become LTS and stop receiving security patches about six months after
# launch, so the image ran an unsupported runtime while the tests proved something
# about a different one. VexSign/Tools/Validation/repository-validation/
# test_runtime_policy.py fails if these drift apart again.
#
# Dependabot has since bumped this image to 26, another odd-numbered Current release.
# That bump is deliberately not taken here: it would reintroduce exactly the drift the
# policy test exists to catch. Move this line together with services.yml's
# `node-version` and `@types/node`, and to the next LTS rather than the newest release.
FROM node:22-bookworm-slim AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY tsconfig.json ./
COPY API ./API
COPY Configuration ./Configuration
COPY Storage ./Storage
COPY Security ./Security
COPY Signing ./Signing
COPY Tests ./Tests
RUN npm run build && npm prune --omit=dev

FROM node:22-bookworm-slim
ENV NODE_ENV=production
WORKDIR /app
COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/dist ./dist
COPY --chown=node:node package*.json ./
COPY --chown=node:node migrations ./migrations
USER node
EXPOSE 8080
CMD ["node", "dist/API/main.js"]
