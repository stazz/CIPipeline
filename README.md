# CIPipeline
This repository contains scripts for CI pipeline, which is suitable for .NET projects with correct folder structure.
The only additional assumption of CI environment is Linux + Docker.

# Requirements and assumptions
The CI pipeline scripts assume the following folder structure to exist:
```
+- Your repository root
   |
   +- This repository as submodule
   |
   +- Source
      |
      +- Directory.Build.props
      |
      +- Code
      |  |
      |  +- ProjectA
      |  |  |
      |  |  +- ProjectA.csproj
      |  |     ...
      |  |
      |  + ProjectB
      |  |  |
      |  |  +- ProjectB.csproj
      |  |     ...
      |  ...
      |
      +- Tests
         |
         +- ProjectA.Tests
         |  |
         |  +- ProjectA.Tests.csproj
         |     ...
         ...
```

All of the code is within `Source` folder in the git repository root, and the `Source` folder has two folders in it, `Code` and `Tests`.
The `Code` has all the actual projects that the git repository contains, each in its own folder.
The `Tests` folder has all the test projects for the projects in `Code` folder.
All of the `.csproj` files within both `Code` and `Tests` folders **must** have the following import:
```xml
<Import Project="$(CIPropsFilePath)" Condition=" '$(CIPropsFilePath)' != '' and Exists('$(CIPropsFilePath)') " />
```

The `Directory.Build.props` file **must** exist in `Source` folder, and must either be copy of `Directory.Build.props.template` file in this repository, or include it via `<Import ... />` element.
The purpose of this `Directory.Build.props` is to make all output go somewhere else than the git repository, as the git repository is mounted as readonly-volume to Docker.


# Usage
The scripts should be executed in the following order:
1. `build.sh` to restore and build all projects (both `Source/Code` and `Source/Tests`),
2. `test.sh` to run the tests exposed by projects in `Source/Tests` folder,
3. `package.sh` to create `.nupkg` files, and
4. `deploy.sh` to upload the `.nupkg` files to NuGet repository, if needed.

All of these scripts will use Docker image `microsoft/dotnet:${DOTNET_VERSION}-sdk-alpine` to perform their actions, and `DOTNET_VERSION` is customizable environment variable.
Furthermore, the `build.sh`, `test.sh`, and `package.sh` scripts all accept optional argument, which is path, relative to the git repository, of the script to run within Docker container.
This script will receive the actual command to run as parameters, and can run it with `"$@"` command.

# The outputs
The following folder structure is the result after a typical successful full run of the pipeline:
```
+- Folder above git repository
   |
   +- Your git repository
   |
   +- output
   |  |
   |  +- Release
   |  |  |
   |  |  +- bin
   |  |  |  |
   |  |  |  +- ProjectA
   |  |  |  |  |
   |  |  |  |  +- netstandard1.0
   |  |  |  |  |  |
   |  |  |  |  |  +- ProjectA.dll
   |  |  |  |  |     ...
   |  |  |  |  ...
   |  |  |  ...
   |  |  |  +- ProjectA.version.nupkg
   |  |  |  ...
   |  |  +- obj
   |  |
   |  +- TestResults
   |     |
   |     +- ProjectA.Tests.trx
   |        ...
   +- secrets
   |  |
   |  +- assembly_key.snk (Created from environment variable)
   |
   +- nuget-packages (NuGet local cache)
   |  |
   |  ...
   +- push-source (NuGet packages actually to be uploaded are copied here)
   |  |
   |  +- ProjectA.version.nupkg
   |     ...
   +- build-success (Used by build.sh to track whether build command was successful)
   |  |
   |  +- ProjectA
   |     ...
   +- test-success (Used by test.sh to track whether build command was successful)
   |  |
   |  +- ProjectA
   |     ...
   +- package-success (Used by package.sh to track whether build command was successful)
      |
      +- ProjectA
         ...
```

The `deploy.sh` script uses the relaxed version of [following git branching model](https://nvie.com/posts/a-successful-git-branching-model/) to decide when it is time to push the .nupkg files to NuGet server.
In short, one needs to create a commit to `master` branch which has the names (without file extension) of all `.nupkg` files that will be published.
The `deploy.sh` script examines the current branch and tags, and when it sees being run on `master` branch with the tags, it will perform publishing using `dotnet nuget push` command (inside Docker container).

# Additional functionality
TODO description about StrongNameSigner

# Additional customization
TODO description about environment variables that are used by scripts, appveyor folder, and AppVeyor.Trx2Json project.