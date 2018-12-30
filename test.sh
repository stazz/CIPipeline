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
  TEST_COMMAND+=(-exec sh -c 'dotnet test -nologo -c Release --no-build --logger trx\;LogFileName=/repo-dir/BuildTarget/TestResults/$(basename {} .csproj).trx /p:IsCIBuild=true "{}" && touch "/success/$(basename {} .csproj)"' \;)
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

  TEST_COMMAND+=(-exec sh -c '/dotnet-tools/coverlet "/repo-dir/BuildTarget/Release/bin/$(basename {} .csproj)/netcoreapp'"${DOTNET_VERSION}"'/$(basename {} .csproj).dll" --target dotnet --targetargs "test -c Release --no-build --logger trx;LogFileName=/repo-dir/BuildTarget/TestResults/$(basename {} .csproj).trx /p:IsCIBuild=true {}" --format opencover --output "/repo-dir/BuildTarget/TestCoverage/$(basename {} .csproj).xml" && touch "/success/$(basename {} .csproj)"' \;)
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
CODECOV_REPORT_DIR="${CS_OUTPUT}/TestCoverage"
if [[ "$(ls -A ${CODECOV_REPORT_DIR})" ]]; then
  # Find out user name and repo name
  if [[ -z "${CODECOV_PAGES_REPO_NAME}" ]]; then
    CODECOV_PAGES_REPO_NAME='ci-codecov-pages.git'
  fi
  GIT_FULL_REMOTE_URL="$(git -C "${GIT_ROOT}" config --local --get remote.origin.url)"
  if [[ -z "${GIT_FULL_REMOTE_URL##*https://*}" ]]; then
    # https is used to clone code repository
    if [[ -z "${CODECOV_PAGES_USER_NAME}" ]]; then
      CODECOV_PAGES_USER_NAME="$(echo "${GIT_FULL_REMOTE_URL}" | awk -F https:// '{printf $2}' | awk -F / '{printf $2}')"
    fi
    if [[ -z "${CODECOV_PAGES_HOST_NAME}" ]]; then
      CODECOV_PAGES_HOST_NAME="$(echo "${GIT_FULL_REMOTE_URL}" | awk -F https:// '{printf $2}' | awk -F / '{printf "git@"$1}')"
    fi
    if [[ -z "${CODECOV_PAGES_THIS_PROJECT_NAME}" ]]; then
      CODECOV_PAGES_THIS_PROJECT_NAME="$(echo "${GIT_FULL_REMOTE_URL}" | awk -F https:// '{printf $2}' | awk -F / '{printf $3}' | awk -F .git '{printf $1}')"
    fi
  else
    # ssh is used to clone code repository
    if [[ -z "${CODECOV_PAGES_USER_NAME}" ]]; then
      CODECOV_PAGES_USER_NAME="$(echo "${GIT_FULL_REMOTE_URL}" | awk -F : '{printf $2}' | awk -F / '{printf $1}')"
    fi
    if [[ -z "${CODECOV_PAGES_HOST_NAME}" ]]; then
      CODECOV_PAGES_HOST_NAME="$(echo "${GIT_FULL_REMOTE_URL}" | awk -F : '{printf $1}')"
    fi
    if [[ -z "${CODECOV_PAGES_THIS_PROJECT_NAME}" ]]; then
      CODECOV_PAGES_THIS_PROJECT_NAME="$(echo "${GIT_FULL_REMOTE_URL}" | awk -F : '{printf $2}' | awk -F / '{printf $2}' | awk -F .git '{printf $1}')"
    fi
  fi

  # Generate the private key file
  CODECOV_PAGES_SSH_KEY_FILE="$(mktemp -p "${BASE_ROOT}")"
  chmod u=rw,g=,o= "${CODECOV_PAGES_SSH_KEY_FILE}"
  # Turn off var expansion when dealing with secure variable
  set +x
  set -v
  echo '-----BEGIN OPENSSH PRIVATE KEY-----' > "${CODECOV_PAGES_SSH_KEY_FILE}"
  echo "${CODECOV_SSH_KEY}" | tr ' ' '\n' >> "${CODECOV_PAGES_SSH_KEY_FILE}"
  echo '-----END OPENSSH PRIVATE KEY-----' >> "${CODECOV_PAGES_SSH_KEY_FILE}"
  # We're done with dealing with secure variable
  set +v
  set -x

  # Pull from the repo
  CODECOV_PAGES_REPO_DIR="${BASE_ROOT}/codecov_pages_repo"
  CODECOV_PAGES_GIT_SSH_COMMAND="ssh -i ${CODECOV_PAGES_SSH_KEY_FILE} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  mkdir "${CODECOV_PAGES_REPO_DIR}"
  git -C "${CODECOV_PAGES_REPO_DIR}" init
  git -C "${CODECOV_PAGES_REPO_DIR}" remote add origin "${CODECOV_PAGES_HOST_NAME}:${CODECOV_PAGES_USER_NAME}/${CODECOV_PAGES_REPO_NAME}"
  git -C "${CODECOV_PAGES_REPO_DIR}" config --local core.sparsecheckout true
  echo "docs/${CODECOV_PAGES_THIS_PROJECT_NAME}" > "${CODECOV_PAGES_REPO_DIR}/.git/info/sparse-checkout"
  echo "history/${CODECOV_PAGES_THIS_PROJECT_NAME}" >> "${CODECOV_PAGES_REPO_DIR}/.git/info/sparse-checkout"
  echo "badges/${CODECOV_PAGES_THIS_PROJECT_NAME}" >> "${CODECOV_PAGES_REPO_DIR}/.git/info/sparse-checkout"
  GIT_SSH_COMMAND="${CODECOV_PAGES_GIT_SSH_COMMAND}" git -C "${CODECOV_PAGES_REPO_DIR}" pull --depth 1 origin master
  # GIT_SSH_COMMAND="${CODECOV_PAGES_GIT_SSH_COMMAND}" git clone --depth=1 --no-checkout "--filter=sparse:path=docs/${CODECOV_PAGES_THIS_PROJECT_NAME}:history/${CODECOV_PAGES_THIS_PROJECT_NAME}:badges/${CODECOV_PAGES_THIS_PROJECT_NAME}" "${CODECOV_PAGES_HOST_NAME}:${CODECOV_PAGES_USER_NAME}/${CODECOV_PAGES_REPO_NAME}" "${CODECOV_PAGES_REPO_DIR}"
  git -C "${CODECOV_PAGES_REPO_DIR}" checkout master -- "docs/${CODECOV_PAGES_THIS_PROJECT_NAME}" "history/${CODECOV_PAGES_THIS_PROJECT_NAME}" "badges/${CODECOV_PAGES_THIS_PROJECT_NAME}"
  # After partial checkout, unstage what git thinks are deletions
  #git -C "${CODECOV_PAGES_REPO_DIR}" ls-tree --name-only -z HEAD docs/ badges/ history/ | xargs --null git -C "${CODECOV_PAGES_REPO_DIR}" reset --


  # Download and install report generator, if needed
  if [[ ! -f "${BASE_ROOT}/dotnet-tools/reportgenerator" ]]; then
    docker run --rm \
      -v "${BASE_ROOT}/dotnet-tools/:/dotnet-tools/:rw" \
      "microsoft/dotnet:${DOTNET_VERSION}-sdk-alpine" \
      dotnet tool install \
      --tool-path /dotnet-tools/ \
      --version 4.0.4 \
      dotnet-reportgenerator-globaltool
  fi
  
  # Create HTML report from all the test projects
  docker run --rm \
    -v "${GIT_ROOT}/:/repo-dir/contents/:ro" \
    -v "${BASE_ROOT}/dotnet-tools/:/dotnet-tools/:ro" \
    -v "${CODECOV_REPORT_DIR}/:/input/:ro" \
    -v "${CODECOV_PAGES_REPO_DIR}/docs/${CODECOV_PAGES_THIS_PROJECT_NAME}/:/output/:rw" \
    -v "${CODECOV_PAGES_REPO_DIR}/history/${CODECOV_PAGES_THIS_PROJECT_NAME}/:/history/:rw" \
    "microsoft/dotnet:${DOTNET_VERSION}-sdk-alpine" \
    '/dotnet-tools/reportgenerator' \
    '-reports:/input/*.xml' \
    '-targetdir:/output' \
    '-reporttypes:html' \
    '-historydir:/history' \
    "-tag:${GIT_COMMIT_HASH}"
  # The HTML report will always have same title, so modify it to better describe what is the report about. The ReportGenerator does not currently provide ability to customize title of the resulting page, so let's just do it by ourselves.
  sed -i "s#<title>Summary - Coverage Report</title>#<title>Coverage Report for ${CODECOV_PAGES_THIS_PROJECT_NAME}</title>#" "${CODECOV_PAGES_REPO_DIR}/docs/${CODECOV_PAGES_THIS_PROJECT_NAME}/index.htm"
  
  # Create Badges from all the test projects
  # We will get "Error during rendering summary report (Report type: 'Badges'): Arial could not be found" but that's related only to .png file generation
  # Since we will be using only .svg anyway, all should be fine.
  docker run --rm \
    -v "${GIT_ROOT}/:/repo-dir/contents/:ro" \
    -v "${BASE_ROOT}/dotnet-tools/:/dotnet-tools/:ro" \
    -v "${CODECOV_REPORT_DIR}/:/input/:ro" \
    -v "${CODECOV_PAGES_REPO_DIR}/badges/${CODECOV_PAGES_THIS_PROJECT_NAME}/total/:/output/:rw" \
    "microsoft/dotnet:${DOTNET_VERSION}-sdk-alpine" \
    '/dotnet-tools/reportgenerator' \
    '-reports:/input/*.xml' \
    '-targetdir:/output/' \
    '-reporttypes:badges'

  # Create badge for each test project
  docker run --rm \
    -v "${GIT_ROOT}/:/repo-dir/contents/:ro" \
    -v "${BASE_ROOT}/dotnet-tools/:/dotnet-tools/:ro" \
    -v "${CODECOV_REPORT_DIR}/:/input/:ro" \
    -v "${CODECOV_PAGES_REPO_DIR}/badges/${CODECOV_PAGES_THIS_PROJECT_NAME}/:/output/:rw" \
    "microsoft/dotnet:${DOTNET_VERSION}-sdk-alpine" \
    find \
    /input \
    -mindepth 1 \
    -maxdepth 1 \
    -type f \
    -name '*.xml' \
    -exec \
    sh -c \
    '/dotnet-tools/reportgenerator -reports:{} -targetdir:/output/project_$(basename {} .xml) -reporttypes:badges' \
    \;

  # Add changes and push the repository (don't show email)
  set +x
  set -v
  git -C "${CODECOV_PAGES_REPO_DIR}" config --local user.email "${CODECOV_PAGES_USER_EMAIL}"
  set -x
  set +v

  git -C "${CODECOV_PAGES_REPO_DIR}" config --local user.name codecoverage-ci-bot
  git -C "${CODECOV_PAGES_REPO_DIR}" add "docs/${CODECOV_PAGES_THIS_PROJECT_NAME}" "history/${CODECOV_PAGES_THIS_PROJECT_NAME}" "badges/${CODECOV_PAGES_THIS_PROJECT_NAME}"
  git -C "${CODECOV_PAGES_REPO_DIR}" commit -m "Project ${CODECOV_PAGES_THIS_PROJECT_NAME}, commit ${GIT_COMMIT_HASH}."
  GIT_SSH_COMMAND="${CODECOV_PAGES_GIT_SSH_COMMAND}" git -C "${CODECOV_PAGES_REPO_DIR}" push origin master
  rm "${CODECOV_PAGES_SSH_KEY_FILE}"
fi
