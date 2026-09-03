# Testing

The core tests use [ShellSpec](https://shellspec.info/) and run the code under test in isolated `zsh -f` subprocesses. The suite also requires `jq` for JSON-related tests.

## Run the test suite

From the repository root:

```zsh
shellspec
```

Run only the core specification while developing:

```zsh
shellspec spec/ulcer-core_spec.sh
```

## Validate syntax

The standalone syntax check does not require ShellSpec:

```zsh
zsh -n ulcer-core.zsh
```

A complete local validation runs both commands:

```zsh
zsh -n ulcer-core.zsh && shellspec
```

The tests use temporary homes, working directories, and configuration files. They do not source the production wrapper scripts or depend on the developer's real configuration.

## Installing ShellSpec

ShellSpec is a development-only dependency. Install it using the package/tool manager used by your environment, then ensure `shellspec` is available on `PATH`. Confirm the required tools are available with:

```zsh
command -v zsh
command -v jq
command -v shellspec
```
