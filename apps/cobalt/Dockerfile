# cobalt's web frontend has no published image (upstream deploys it to Cloudflare
# Pages), so it's built from source. WEB_HOST and WEB_DEFAULT_API are baked into
# the static bundle at build time and cannot be changed at runtime.
FROM node:23-alpine AS build

ARG COBALT_REF=main
ARG WEB_HOST
ARG WEB_DEFAULT_API
ENV WEB_HOST=${WEB_HOST}
ENV WEB_DEFAULT_API=${WEB_DEFAULT_API}

RUN apk add --no-cache git && corepack enable

WORKDIR /src
RUN git clone --branch "${COBALT_REF}" --single-branch https://github.com/imputnet/cobalt.git .
RUN pnpm install --frozen-lockfile --filter=./web
RUN pnpm run --filter=./web build

# The build emits a `_headers` file that only Cloudflare Pages understands, so the
# cross-origin isolation it declares is reapplied in nginx.conf instead.
FROM nginx:1.29-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /src/web/build /usr/share/nginx/html
EXPOSE 3000
