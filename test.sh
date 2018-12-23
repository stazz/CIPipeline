#!/bin/bash

set -xe

SCRIPTPATH=$(readlink -f "$0")
SCRIPTDIR=$(dirname "$SCRIPTPATH")
GIT_ROOT=$(readlink -f "${SCRIPTDIR}/..")
BASE_ROOT=$(readlink -f "${GIT_ROOT}/..")

TEST_PROJECT_COUNT=$(find "${GIT_ROOT}/Source/Tests" -mindepth 2 -maxdepth 2 -type f -name *.csproj | wc -l)
if [[ "${TEST_PROJECT_COUNT}" -eq "0" ]]; then
  if [[ "${NO_TESTS_IS_OK}" ]]; then
    exit 0
  else
    echo "Please make at least one test project or set NO_TESTS_IS_OK variable to non-empty string."
    exit 1
  fi
fi

if [[ "${RELATIVE_NUGET_PACKAGE_DIR}" ]]; then
  NUGET_PACKAGE_DIR=$(readlink -f "${BASE_ROOT}/${RELATIVE_NUGET_PACKAGE_DIR}")
fi

if [[ "${RELATIVE_CS_OUTPUT}" ]]; then
  CS_OUTPUT=$(readlink -f "${BASE_ROOT}/${RELATIVE_CS_OUTPUT}")
fi

# Run tests with hard-coded trx format, for now.
SUCCESS_DIR="${BASE_ROOT}/test-success"
TEST_COMMAND=(find /repo-dir/contents/Source/Tests -mindepth 2 -maxdepth 2 -type f -name *.csproj -exec sh -c 'dotnet test -nologo -c Release --no-build --logger trx\;LogFileName=/repo-dir/BuildTarget/TestResults/$(basename {} .csproj).trx /p:IsCIBuild=true {} && touch "/success/$(basename {} .csproj)"' \;)

if [[ "${TEST_SCRIPT_WITHIN_CONTAINER}" ]]; then
  # Our actual command is to invoke a script within GIT repository, and passing it the command as parameter
  TEST_COMMAND=("/repo-dir/contents/${TEST_SCRIPT_WITHIN_CONTAINER}" "${TEST_COMMAND[@]}")
fi

ADDITIONAL_VOLUMES=()
if [[ "${ADDITIONAL_VOLUME_DIRECTORIES}" ]]; then
  IFS=', ' read -r -a volume_dir_array <<< "${ADDITIONAL_VOLUME_DIRECTORIES}"
  for volume_dir in "${volume_dir_array[@]}"
  do
    ADDITIONAL_VOLUMES+=('-v' "${BASE_ROOT}/${volume_dir}:/repo-dir/${volume_dir}/:ro")
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

if [[ "${TEST_BEFORE_DOCKER_SCRIPT}" ]]; then
  BEFORE_AFTER_SCRIPT_DIR="$(mktemp -d -p "${BASE_ROOT}")"
  "${GIT_ROOT}/${TEST_BEFORE_DOCKER_SCRIPT}" "${BEFORE_AFTER_SCRIPT_DIR}"
fi

# Run tests code within docker
rm -rf "${SUCCESS_DIR}"
docker run \
  --rm \
  -v "${GIT_ROOT}/:/repo-dir/contents/:ro" \
  -v "${CS_OUTPUT}/:/repo-dir/BuildTarget/:rw" \
  -v "${NUGET_PACKAGE_DIR}/:/root/.nuget/packages/:rw" \
  -v "${SUCCESS_DIR}/:/success/:rw" \
  "${ADDITIONAL_VOLUMES[@]}" \
  -u 0 \
  -e "THIS_TFM=netcoreapp${DOTNET_VERSION}" \
  -e "CI_FOLDER=${CI_FOLDER}" \
  -e "GIT_COMMIT_HASH=${GIT_COMMIT_HASH}" \
  "${ADDITIONAL_ENV[@]}" \
  --network cbam_test_nw \
  "microsoft/dotnet:${DOTNET_VERSION}-sdk-alpine" \
  "${TEST_COMMAND[@]}"

if [[ "${TEST_AFTER_DOCKER_SCRIPT}" ]]; then
  if [[ -z "${BEFORE_AFTER_SCRIPT_DIR}" ]]; then
    BEFORE_AFTER_SCRIPT_DIR="$(mktemp -d -p "${BASE_ROOT}")"
  fi

  "${GIT_ROOT}/${TEST_AFTER_DOCKER_SCRIPT}" "${BEFORE_AFTER_SCRIPT_DIR}"
fi
  
# Run custom script if it is given
if [[ "$1" ]]; then
  readarray -t TEST_REPORTS < <(find "${CS_OUTPUT}/TestResults" -name *.trx)
  "$1" "${TEST_REPORTS[@]}"
fi

# Verify that all test projects produced test report
TEST_SUCCESS_COUNT=$(find "${SUCCESS_DIR}" -mindepth 1 -maxdepth 1 -type f | wc -l)

if [[ "${TEST_PROJECT_COUNT}" -ne "${TEST_SUCCESS_COUNT}" ]]; then
 echo "One or more project did not produce test report successfully." 1>&2
 exit 1
fi
  
# Verify that all tests in all test reports are passed.
# Enumerate all .trx files, for each of those execute Python one-liner to get amount of executed and passed tests, print them out and save to array.
# Each array element is two numbers separated by space character - first is executed count, second is passed count.
readarray -t TEST_RESULTS < <(find "${CS_OUTPUT}/TestResults" -name *.trx -exec python3 -c "from xml.etree.ElementTree import ElementTree; doc = ElementTree(file='{}'); docNS = doc.getroot().tag.split('}')[0].strip('{'); counters = doc.find('test_ns:ResultSummary/test_ns:Counters', { 'test_ns': docNS }); print(counters.attrib['executed'] + ' ' + counters.attrib['passed']);" \;)
# Walk each array element and make sure that first number matches second
for TEST_RESULT in "${TEST_RESULTS[@]}"; do
  EXECUTED_AND_PASSED=(${TEST_RESULT})
  if [[ "${EXECUTED_AND_PASSED[0]}" -ne "${EXECUTED_AND_PASSED[1]}" ]]; then
    exit 1
  fi
done
