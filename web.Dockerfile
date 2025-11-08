FROM nginx:alpine
RUN rm -f /etc/nginx/conf.d/default.conf
COPY web/public /usr/share/nginx/html
# Ensure nginx can read everything regardless of host umask
RUN find /usr/share/nginx/html -type d -exec chmod 0755 {} \; \
 && find /usr/share/nginx/html -type f -exec chmod 0644 {} \;
RUN printf '%s\n' \
 'server {' \
 '  listen 80;' \
 '  server_name _;' \
 '  root /usr/share/nginx/html;' \
 '  index index.html;' \
 '  location / { try_files $uri $uri/ /index.html; }' \
 '  location ~* \.(?:js|css|png|jpg|jpeg|gif|svg|ico|woff2?)$ { try_files $uri =404; expires 7d; add_header Cache-Control "public"; }' \
 '}' > /etc/nginx/conf.d/default.conf
