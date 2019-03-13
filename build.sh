#!/bin/bash

set -xe

# Find out the path and directory where this script resides
SCRIPTPATH=$(readlink -f "$0")
SCRIPTDIR=$(dirname "$SCRIPTPATH")
GIT_ROOT=$(readlink -f "${SCRIPTDIR}/..")
BASE_ROOT=$(readlink -f "${GIT_ROOT}/..")

# Copy required files to GIT root
cp "${SCRIPTDIR}/CISupport.props" "${GIT_ROOT}/CISupport.props"
cp "${SCRIPTDIR}/NuGet.Config" "${GIT_ROOT}/NuGet.Config.ci"

# Create key
set -v
set +x
if [[ "${ASSEMBLY_SIGN_KEY}" ]]; then
  mkdir -p "${BASE_ROOT}/secrets"
  echo "${ASSEMBLY_SIGN_KEY}" | base64 -d > "${BASE_ROOT}/secrets/assembly_key.snk"
fi
set +v
set -x

if [[ "${RELATIVE_NUGET_PACKAGE_DIR}" ]]; then
  NUGET_PACKAGE_DIR=$(readlink -f "${BASE_ROOT}/${RELATIVE_NUGET_PACKAGE_DIR}")
fi

if [[ "${RELATIVE_CS_OUTPUT}" ]]; then
  CS_OUTPUT=$(readlink -f "${BASE_ROOT}/${RELATIVE_CS_OUTPUT}")
fi

if [[ "${RELATIVE_REDIST_LISTS}" ]]; then
  REDIST_LISTS=$(readlink -f "${BASE_ROOT}/${RELATIVE_REDIST_LISTS}")
fi

GIT_COMMIT_HASH=$(git -C "${GIT_ROOT}" show-ref --hash HEAD)
# Originally build success dir was inside the CS_OUTPUT, but that caused MSB4024 issue with generated .nuget.g.props files (dotnet claimed that file did not exist) on Windows at least, so maybe Docker or other issue. In any case, this works when the build success dir is not inside the shared CS_OUTPUT.
SUCCESS_DIR="${BASE_ROOT}/build-success"
BUILD_COMMAND=(find /repo-dir/contents/Source/Code /repo-dir/contents/Source/Tests -mindepth 2 -maxdepth 2 -type f -name *.csproj -exec sh -c "dotnet build -nologo /p:Configuration=Release /p:IsCIBuild=true /p:CIPackageVersionSuffix=${GIT_COMMIT_HASH} {}"' && touch "/success/$(basename {} .csproj)"' \;)

if [[ "${BUILD_SCRIPT_WITHIN_CONTAINER}" ]]; then
  # Our actual command is to invoke a script within GIT repository, and passing it the command as parameter
  BUILD_COMMAND=("/repo-dir/contents/${BUILD_SCRIPT_WITHIN_CONTAINER}" "${BUILD_COMMAND[@]}")
fi

ADDITIONAL_VOLUMES=()
if [[ "${ADDITIONAL_VOLUME_DIRECTORIES}" ]]; then
  # Crucial to leave unquoted in order to make it work
  VOLUME_DIR_ARRAY=(${ADDITIONAL_VOLUME_DIRECTORIES})
  for VOLUME_DIR in "${VOLUME_DIR_ARRAY[@]}"
  do
    ADDITIONAL_VOLUMES+=('-v' "${BASE_ROOT}/${VOLUME_DIR}:/repo-dir/${VOLUME_DIR}/:ro")
  done
fi

if [[ -f "${BASE_ROOT}/secrets/assembly_key.snk" ]]; then
  ADDITIONAL_VOLUMES+=('-v' "${BASE_ROOT}/secrets/assembly_key.snk:/repo-dir/secrets/assembly_key.snk:ro")
fi

ADDITIONAL_ENV=()
if [[ "${ADDITIONAL_ENVIRONMENT_VARS}" ]]; then
  # Crucial to leave unquoted in order to make it work
  env_array=($ADDITIONAL_ENVIRONMENT_VARS)
  for var_name in "${env_array[@]}"; do
    ADDITIONAL_ENV+=('-e' "${var_name}=${!var_name}")
  done
fi

# Build code within docker
rm -rf "$SUCCESS_DIR"
rm -rf "${CS_OUTPUT}"
docker run \
  --rm \
  -v "${GIT_ROOT}/:/repo-dir/contents/:ro" \
  -v "${CS_OUTPUT}/:/repo-dir/BuildTarget/:rw" \
  -v "${GIT_ROOT}/NuGet.Config.ci:/root/.nuget/NuGet/NuGet.Config:ro" \
  -v "${NUGET_PACKAGE_DIR}/:/root/.nuget/packages/:rw" \
  -v "${REDIST_LISTS}/:/repo-dir/redistlists/:rw" \
  -v "${SUCCESS_DIR}/:/success/:rw" \
  "${ADDITIONAL_VOLUMES[@]}" \
  -u 0 \
  -e "THIS_TFM=netcoreapp${DOTNET_VERSION}" \
  -e "CI_FOLDER=${CI_FOLDER}" \
  -e "GIT_COMMIT_HASH=${GIT_COMMIT_HASH}" \
  "${ADDITIONAL_ENV[@]}" \
  "microsoft/dotnet:${DOTNET_VERSION}-sdk-alpine" \
  "${BUILD_COMMAND[@]}"
  
# Because find does not return non-0 exit code even when its -exec command does, we need to make sure that we have actually built all of them successfully
SOURCE_PROJECT_COUNT=$(find "${GIT_ROOT}/Source/Code" "${GIT_ROOT}/Source/Tests" -mindepth 2 -maxdepth 2 -type f -name *.csproj | wc -l)

# Get amount of files created by touch
SOURCE_BUILD_SUCCESS_COUNT=$(find "${SUCCESS_DIR}" -mindepth 1 -maxdepth 1 -type f | wc -l)

if [[ ${SOURCE_PROJECT_COUNT} -ne ${SOURCE_BUILD_SUCCESS_COUNT} ]]; then
  echo "One or more project did not build successfully." 1>&2
  exit 1
fi

# Run custom script if it is given
if [[ "$1" ]]; then
  # readarray -t BUILD_ASSEMBLIES < <(find "${CS_OUTPUT}/Release/bin/" -mindepth 3 -maxdepth 3 -type f -name "${ASSEMBLY_PREFIX}*.dll")
  "$1" # "${BUILD_ASSEMBLIES[@]}"
fi
