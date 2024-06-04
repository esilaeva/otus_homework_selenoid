#!/bin/bash

# Checking for arguments
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <browser_name> <browser_version>"
    exit 1
fi

BROWSER_NAME=$1
BROWSER_VERSION=$2

# Setting the required variables
SELENOID_DIR="$HOME/selenoid_script"
BROWSERS_JSON="$SELENOID_DIR/browsers.json"
QUOTA_XML="$SELENOID_DIR/grid-router/quota/test.xml"
DOCKER_COMPOSE_FILE="$SELENOID_DIR/docker-compose.yaml"
NGINX_CONF="$SELENOID_DIR/nginx/default.conf"
NETWORK="selenoid"

# Creating the necessary directories 
mkdir -p "$SELENOID_DIR"
mkdir -p "$(dirname "$QUOTA_XML")"
mkdir -p "$(dirname "$NGINX_CONF")"

# Create docker-compose.yaml, if it doesn't exist
if [ ! -f "$DOCKER_COMPOSE_FILE" ]; then
cat <<EOF > "$DOCKER_COMPOSE_FILE"
version: '3.7'

services:
  selenoid:
    container_name: selenoid
    image: aerokube/selenoid:1.11.3
    networks:
      - $NETWORK
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - $BROWSERS_JSON:/etc/selenoid/browsers.json:ro
    command:
      - "-container-network=$NETWORK"
      - "-limit=12"

  ggr:
    container_name: ggr
    depends_on:
      - selenoid
    image: aerokube/ggr:1.7.2
    networks:
      - $NETWORK
    volumes:
      - $SELENOID_DIR/grid-router:/etc/grid-router:ro
    command:
      - "-guests-allowed"
      - "-guests-quota=test"
      - "-verbose"
      - "-quotaDir=/etc/grid-router/quota"
    ports:
      - "4444:4444"

  ggr-ui:
    container_name: ggr-ui
    depends_on:
      - ggr
    image: aerokube/ggr-ui:1.2.0
    networks:
      - $NETWORK
    volumes:
      - $SELENOID_DIR/grid-router/quota:/etc/grid-router/quota:ro 

  selenoid-ui:
    container_name: selenoid-ui
    depends_on:
      - ggr-ui
    image: aerokube/selenoid-ui:1.8.0
    networks:
      - $NETWORK
    command:
      - "--selenoid-uri"
      - "http://ggr-ui:8888"
    ports:
      - "8080:8080"

  nginx:
    container_name: nginx
    depends_on:
      - selenoid-ui
    image: nginx:latest
    networks:
      - $NETWORK
    ports:
      - "80:80"
    volumes:
      - $SELENOID_DIR/nginx:/etc/nginx/conf.d:ro

networks:
  $NETWORK:
    name: $NETWORK
    external: true
EOF
fi

# Update browsers.json
  cat <<EOF > "$BROWSERS_JSON"
{
  "$BROWSER_NAME": {
    "default": "$BROWSER_VERSION",
    "versions": {
      "$BROWSER_VERSION": {
        "image": "selenoid/$BROWSER_NAME:$BROWSER_VERSION",
        "port": "4444",
       "path": "/"
      }
    }
  }
}
EOF


if ! docker network ls | grep -q "$NETWORK"; then
    docker network create "$NETWORK"
else
    echo "Network $NETWORK already exists."
fi
docker pull selenoid/$BROWSER_NAME:$BROWSER_VERSION

# Update test.xml
cat <<EOF > "$QUOTA_XML"
<qa:browsers xmlns:qa="urn:config.gridrouter.qatools.ru">
  <browser name="$BROWSER_NAME" defaultVersion="$BROWSER_VERSION">
    <version number="$BROWSER_VERSION">
      <region name="default">
        <host name="$NETWORK" port="4444" count="1"/>
      </region>
    </version>
  </browser>
</qa:browsers>
EOF

# Creating Nginx configuration
if [ ! -f "$NGINX_CONF" ]; then
  cat <<EOF > "$NGINX_CONF"
upstream selenoid-ui {
  random;
  server selenoid-ui:8080;
}

upstream ggr {
  random;
  server ggr:4444;
}

server {
  listen 80 default_server;

  add_header 'Access-Control-Allow-Origin' '*';
  add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
  add_header 'Access-Control-Allow-Headers' 'Origin, X-Requested-With, Content-Type, Accept, Authorization';

  location / {
    proxy_pass http://selenoid-ui/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "Upgrade";
    proxy_set_header Host \$host;
    proxy_buffering off;
  }

  location ~* \.(js|css|media|status|events|vnc|logs)/ {
    proxy_pass http://selenoid-ui;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "Upgrade";
    proxy_set_header Host \$host;
  }

  location /wd/hub/ {
    proxy_pass http://ggr;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "Upgrade";
    proxy_set_header Host \$host;
    proxy_buffering off;
  }
}
EOF
else
  echo "$NGINX_CONF already exists."
fi

# Creating an .env file
cat <<EOF > "$SELENOID_DIR/.env"
BROWSERS_JSON=$BROWSERS_JSON
SELENOID_DIR=$SELENOID_DIR
NETWORK=$NETWORK
BROWSER_IMAGE=$BROWSER_IMAGE
EOF

# Starting services with Docker Compose
cd "$SELENOID_DIR"
docker-compose up -d

echo "Selenoid and related services have been successfully launched!"
