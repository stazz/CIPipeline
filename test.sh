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
TEST_COMMAND=(find /repo-dir/contents/Source/Tests -mindepth 2 -maxdepth 2 -type f -name *.csproj)
if [[ "${NO_TEST_COVERAGE}" ]]; then
  TEST_COMMAND+=(-exec sh -c 'dotnet test -nologo -c Release --no-build --logger trx\;LogFileName=/repo-dir/BuildTarget/TestResults/$(basename {} .csproj).trx /p:IsCIBuild=true {} && touch "/success/$(basename {} .csproj)"' \;)
else
  # First install the coverlet .NET Core tool
  if [[ ! -f "${BASE_ROOT}/dotnet-tools/coverlet" ]]; then
    docker run --rm \
      -v "${BASE_ROOT}/dotnet-tools/:/dotnet-tools/:rw" \
      "microsoft/dotnet:${DOTNET_VERSION}-sdk-alpine" \
      dotnet tool install \
      --tool-path /dotnet-tools/ \
      --version 1.3.0 \
      coverlet.console
  fi

  # Because of how coverlet works, we must actually build command manually
  TEST_COMMAND[1]="${GIT_ROOT}/Source/Tests"
  readarray -t TEST_PROJECTS < <("${TEST_COMMAND[@]}")
  TEST_COMMAND=()
  COVERLET="/dotnet-tools/coverlet"
  for TEST_IDX in "${!TEST_PROJECTS[@]}"; do
    TEST_PROJECT_NAME="$(basename ${TEST_PROJECTS[$TEST_IDX]} .csproj)"
    TEST_COMMAND+=("${COVERLET}" "/repo-dir/BuildTarget/Release/bin/${TEST_PROJECT_NAME}/netcoreapp${DOTNET_VERSION}/${TEST_PROJECT_NAME}.dll" --target dotnet --targetargs "'test -c Release --no-build --logger trx;LogFileName=/repo-dir/BuildTarget/TestResults/${TEST_PROJECT_NAME}.trx /repo-dir/contents/Source/Tests/${TEST_PROJECT_NAME}/${TEST_PROJECT_NAME}.csproj'")
    if [[ "${TEST_IDX}" -gt 0 ]]; then
      # Merge with previous codecoverage results
      TEST_COMMAND+=('--merge-with' "/repo-dir/BuildTarget/TestCoverage/$(basename ${TEST_PROJECTS[${TEST_IDX}-1]} .csproj).coverage.json")
    fi
    if [[ $(("${TEST_IDX}"+1)) -eq "${#TEST_PROJECTS[@]}" ]]; then
      # Last element -> format is opencover, output file path always same
      TEST_COMMAND+=('--format' 'opencover' '--output' "/repo-dir/BuildTarget/TestCoverage/coverage.opencover.xml")
    else
      # More to come -> format is json, output file depends on project name
      TEST_COMMAND+=('--format' 'json' '--output' "/repo-dir/BuildTarget/TestCoverage/${TEST_PROJECT_NAME}.coverage.json")
    fi
    TEST_COMMAND+=('&&' 'touch' "/success/${TEST_PROJECT_NAME}" ';')
  done
  TEST_COMMAND+=('exit' '0' ';')
  TEST_COMMAND=('sh' '-c' "`echo "${TEST_COMMAND[@]}"`")
fi

if [[ "${TEST_SCRIPT_WITHIN_CONTAINER}" ]]; then
  # Our actual command is to invoke a script within GIT repository, and passing it the command as parameter
  TEST_COMMAND=("/repo-dir/contents/${TEST_SCRIPT_WITHIN_CONTAINER}" "${TEST_COMMAND[@]}")
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

if [[ -z "${NO_TEST_COVERAGE}" ]]; then
  ADDITIONAL_VOLUMES+=('-v' "${BASE_ROOT}/dotnet-tools/:/dotnet-tools/:rw")
fi

ADDITIONAL_ENV=()
if [[ "${ADDITIONAL_ENVIRONMENT_VARS}" ]]; then
  # Crucial to leave unquoted in order to make it work
  env_array=($ADDITIONAL_ENVIRONMENT_VARS)
  for var_name in "${env_array[@]}"; do
    ADDITIONAL_ENV+=('-e' "${var_name}=${!var_name}")
  done
fi

ADDITIONAL_DOCKER_ARGS=(${TEST_ADDITIONAL_DOCKER_ARGS})

if [[ "${TEST_BEFORE_DOCKER_SCRIPT}" ]]; then
  BEFORE_AFTER_SCRIPT_DIR="$(mktemp -d -p "${BASE_ROOT}")"
  "${GIT_ROOT}/${TEST_BEFORE_DOCKER_SCRIPT}" "${BEFORE_AFTER_SCRIPT_DIR}"
fi

GIT_COMMIT_HASH=$(git -C "${GIT_ROOT}" show-ref --hash HEAD)

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
  "${ADDITIONAL_DOCKER_ARGS[@]}" \
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

# Upload coverage report if all tests are successful and if the report exists
if [[ -f "${CS_OUTPUT}/TestCoverage/coverage.opencover.xml" ]]; then
  # Download the uploader first if it isn't already
  CODECOV_UPLOADER="${BASE_ROOT}/coverage-tools/codecov-upload.sh"
  if [[ ! -f "${CODECOV_UPLOADER}" ]]; then
    mkdir -p "$(dirname "${CODECOV_UPLOADER}")"
    # Download the uploader first
    curl -o "${CODECOV_UPLOADER}" 'https://codecov.io/bash'
  fi
  chmod +x "${CODECOV_UPLOADER}"

  # The coverage file will contain file paths, which resolve within the container, but not outside of it
  # We can either upload from within another container (which can't be alpine-based, since it is bash script instead of sh script)
  # Or we can just make symlink
  sudo mkdir -p /repo-dir/contents/
  sudo chmod o+rwX /repo-dir/
  sudo chmod o+rwX /repo-dir/contents/
  ln -sf "${GIT_ROOT}/" /repo-dir/contents/
  # Turn off var expansion when dealing with secure variable
  set -v
  set +x
  "${CODECOV_UPLOADER}" -f "${CS_OUTPUT}/TestCoverage/coverage.opencover.xml" -t "${CODECOV_TOKEN}" -Z
  #  -n "commit-${GIT_COMMIT_HASH}"
  set +v
  set -x
fi
