#!/bin/bash

echo "Building autossh container image..."

CONTAINER_FILE=Containerfile

read -r NAME VERSION < <(awk '
  BEGIN { to_remove_regex = ".*=|[\"\\\\/]+| +$|^ +" }
  /org.opencontainers.image.ref.name/{gsub(to_remove_regex,"", $0); name=$0}
  /org.opencontainers.image.version/{gsub(to_remove_regex,"", $0); version=$0} 
  END{print name, version}' $CONTAINER_FILE)

podman build \
  --arch amd64 \
  --build-arg CREATED_DATETIME="$(date -u  +'%Y-%m-%dT%H:%M:%S%:z')" \
  --tag $NAME:$VERSION \
  --file $CONTAINER_FILE

echo "Finished building $NAME:$VERSION"
