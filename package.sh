#!/bin/bash

set -xe

# Find out the path and directory where this script resides
SCRIPTPATH=$(readlink -f "$0")
SCRIPTDIR=$(dirname "$SCRIPTPATH")
GIT_ROOT=$(readlink -f "${SCRIPTDIR}/..")
BASE_ROOT=$(readlink -f "${GIT_ROOT}/..")

if [[ "${RELATIVE_NUGET_PACKAGE_DIR}" ]]; then
  NUGET_PACKAGE_DIR=$(readlink -f "${BASE_ROOT}/${RELATIVE_NUGET_PACKAGE_DIR}")
fi

if [[ "${RELATIVE_CS_OUTPUT}" ]]; then
  CS_OUTPUT=$(readlink -f "${BASE_ROOT}/${RELATIVE_CS_OUTPUT}")
fi

if [[ "${RELATIVE_REDIST_LISTS}" ]]; then
  REDIST_LISTS=$(readlink -f "${BASE_ROOT}/${RELATIVE_REDIST_LISTS}")
fi

# Using dotnet build /t:Pack will cause re-build even with /p:GeneratePackageOnBuild=false /p:NoBuild=true flags, so just use dotnet pack instead
GIT_COMMIT_HASH=$(git -C "${GIT_ROOT}" show-ref --hash HEAD)
SUCCESS_DIR="${BASE_ROOT}/package-success"
if [[ "${DEPLOY_NUGET_NO_SYMBOLS}" ]]; then
  PACKAGE_COMMAND=()
else
  PACKAGE_COMMAND=('--include-symbols' '/p:SymbolPackageFormat=snupkg')
fi

PACKAGE_COMMAND=(find /repo-dir/contents/Source/Code -mindepth 2 -maxdepth 2 -type f -name *.csproj -exec sh -c "dotnet pack -nologo -c Release --no-build /p:IsCIBuild=true /p:CIPackageVersionSuffix=${GIT_COMMIT_HASH} `echo ${PACKAGE_COMMAND[@]}` {}"' && touch "/success/$(basename {} .csproj)"' \;)


if [[ "${PACKAGE_SCRIPT_WITHIN_CONTAINER}" ]]; then
  # Our actual command is to invoke a script within GIT repository, and passing it the command as parameter
  PACKAGE_COMMAND=("/repo-dir/contents/${PACKAGE_SCRIPT_WITHIN_CONTAINER}" "${PACKAGE_COMMAND[@]}")
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

# Run package code within docker
rm -rf "${SUCCESS_DIR}"
docker run \
  --rm \
  -v "${GIT_ROOT}/:/repo-dir/contents/:ro" \
  -v "${CS_OUTPUT}/:/repo-dir/BuildTarget/:rw" \
  -v "${NUGET_PACKAGE_DIR}/:/root/.nuget/packages/:rw" \
  -v "${REDIST_LISTS}/:/repo-dir/redistlists/:ro" \
  -v "${SUCCESS_DIR}/:/success/:rw" \
  "${ADDITIONAL_VOLUMES[@]}" \
  -u 0 \
  -e "THIS_TFM=netcoreapp${DOTNET_VERSION}" \
  -e "CI_FOLDER=${CI_FOLDER}" \
  -e "GIT_COMMIT_HASH=${GIT_COMMIT_HASH}" \
  "${ADDITIONAL_ENV[@]}" \
  "microsoft/dotnet:${DOTNET_VERSION}-sdk-alpine" \
  "${PACKAGE_COMMAND[@]}"

# Verify that all test projects produced test report
PACKAGE_PROJECT_COUNT=$(find "${GIT_ROOT}/Source/Code" -mindepth 2 -maxdepth 2 -type f -name *.csproj | wc -l)
PACKAGE_SUCCESS_COUNT=$(find "${SUCCESS_DIR}" -mindepth 1 -maxdepth 1 -type f | wc -l)

if [[ ${PACKAGE_PROJECT_COUNT} -ne ${PACKAGE_SUCCESS_COUNT} ]]; then
 echo "One or more project did not package successfully." 1>&2
 exit 1
fi

# Run custom script if it is given
if [[ "$1" ]]; then
  readarray -t PACKAGE_FILES < <(find "${CS_OUTPUT}/Release/bin" -mindepth 1 -maxdepth 1 -type f -name *.*nupkg)
  "$1" "${PACKAGE_FILES[@]}"
fi
