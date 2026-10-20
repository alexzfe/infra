# Copy to <app repo>/Dockerfile for a static site (Vite, Astro, plain HTML).
# Builds the site, then serves it with nginx on :8080, the port sites.yml expects. The unprivileged image runs as a
# non-root user and listens on 8080 out of the box.
FROM node:22-alpine AS build
WORKDIR /app
RUN corepack enable
COPY . .
# Adjust to the repo: e.g. `pnpm install --frozen-lockfile && pnpm --filter @bgt/arcade build`
RUN pnpm install --frozen-lockfile && pnpm build

FROM nginxinc/nginx-unprivileged:1.28-alpine
# Adjust the source path to wherever the build writes (apps/arcade/dist for the arcade).
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 8080
