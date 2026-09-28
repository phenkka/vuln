# Frontend: сборка на устаревшем node, раздача старым nginx, root, без HEALTHCHECK.
FROM node:14-alpine AS builder
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY src ./dist
RUN mkdir -p dist/vendor \
 && cp node_modules/jquery/dist/jquery.min.js dist/vendor/ \
 && cp node_modules/lodash/lodash.min.js dist/vendor/ \
 && cp node_modules/axios/dist/axios.min.js dist/vendor/

FROM nginx:1.18-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=builder /app/dist /usr/share/nginx/html
EXPOSE 80
