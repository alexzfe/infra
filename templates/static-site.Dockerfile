# Copy to <app repo>/Dockerfile for a static site (Vite, Astro, plain HTML).
# Builds the site, then serves it with Caddy on :8080, the port sites.yml expects.
FROM node:22-alpine AS build
WORKDIR /app
RUN corepack enable
COPY . .
# Adjust to the repo: e.g. `pnpm install --frozen-lockfile && pnpm --filter @bgt/arcade build`
RUN pnpm install --frozen-lockfile && pnpm build

FROM caddy:2.10-alpine
# Adjust the source path to wherever the build writes (apps/arcade/dist for the arcade).
COPY --from=build /app/dist /srv
EXPOSE 8080
CMD ["caddy", "file-server", "--root", "/srv", "--listen", ":8080"]
