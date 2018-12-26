#!/bin/bash

set -xe

DOCKER_IMAGE_NAME="$1"
DOCKER_IMAGE_FILE="$2"

mkdir -p "$(dirname "${DOCKER_IMAGE_FILE}")"
# First, check if the save image file exists
if [[ -f "${DOCKER_IMAGE_FILE}" ]]; then
  # Load image
  docker image load -i "${DOCKER_IMAGE_FILE}"

  # Get image ID (when changing image, we will get an error that no such image is available, ignore that)
  set +e
  DOCKER_IMAGE_ID="$(docker image inspect -f '{{ .Id }}' "${DOCKER_IMAGE_NAME}")"
  set -e
  
  # Pull image
  docker pull "${DOCKER_IMAGE_NAME}"

  # Get new ID
  DOCKER_IMAGE_ID_NEW="$(docker image inspect -f '{{ .Id }}' "${DOCKER_IMAGE_NAME}")"

  # Save if new ID is different (we pulled new version)
  if [[ "${DOCKER_IMAGE_ID}" != "${DOCKER_IMAGE_ID_NEW}" ]]; then
    docker image save -o "${DOCKER_IMAGE_FILE}" "${DOCKER_IMAGE_NAME}"
  fi
else
  # Pull image
  docker pull "${DOCKER_IMAGE_NAME}"

  # Save image to disk
  docker image save -o "${DOCKER_IMAGE_FILE}" "${DOCKER_IMAGE_NAME}" 
fi


