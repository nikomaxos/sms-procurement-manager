FROM node:22-alpine as build
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .
RUN npm run build
FROM caddy:2.8.4-alpine
COPY --from=build /app/dist /usr/share/caddy
