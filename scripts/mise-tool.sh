#!/usr/bin/env bash
# Shared pinned-tool helper for SweetMX hooks, scripts, and Makefile targets.
# Reads exact tool versions from mise.toml [tools], resolves mise bin-paths
# without trusting or prompting on untrusted local mise.toml files, and fails
# closed on missing or mismatched tool versions.
#
# Usage (direct CLI):
#   scripts/mise-tool.sh check <swiftformat|swiftlint>
#   scripts/mise-tool.sh run <swiftformat|swiftlint> [--] [args...]
#
# Usage (sourced by scripts/lint-scripts.sh):
#   . "$script_dir/mise-tool.sh"
set -euo pipefail

readonly MISE_CONFIG_REL='mise.toml'
readonly SWIFTFORMAT_RELEASE_URL_PREFIX='https://github.com/nicklockwood/SwiftFormat/releases/tag/'
readonly SWIFTLINT_RELEASE_URL_PREFIX='https://github.com/realm/SwiftLint/releases/tag/'

# parse_mise_pin <mise_config_path> <tool>
parse_mise_pin() {
	local mise_config="$1"
	local tool="$2"
	if [ -L "$mise_config" ] || [ ! -f "$mise_config" ] || [ ! -s "$mise_config" ]; then
		echo "mise-tool: missing, empty, or symlinked $mise_config" >&2
		exit 1
	fi
	# Parse TOML as data. Local mise configuration can contain executable settings.
	uv --no-config run --offline --no-project --managed-python --python '>=3.11' \
		python -I - "$mise_config" "$tool" <<'PY'
import re
import sys
import tomllib

config, tool = sys.argv[1:]
try:
    with open(config, "rb") as source:
        pin = tomllib.load(source)["tools"][tool]
except (KeyError, OSError, TypeError, ValueError) as exc:
    sys.exit(f"mise-tool: cannot read [tools].{tool} from {config}: {exc}")
if not isinstance(pin, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", pin):
    sys.exit(f"mise-tool: expected an exact version for [tools].{tool} in {config}")
print(pin)
PY
}

# prepend_pinned_mise_paths <repo_root> <tool@version>...
prepend_pinned_mise_paths() {
	local repo_root="$1"
	shift
	local pinned_paths=""
	if command -v mise >/dev/null 2>&1 && [ "$#" -gt 0 ]; then
		# Disable local config loading so MISE_PARANOID=1 never aborts or prompts
		# inside an untrusted staged snapshot or at_sha detached worktree.
		pinned_paths=$(
			MISE_NO_CONFIG=1 \
				MISE_IGNORED_CONFIG_PATHS="${MISE_IGNORED_CONFIG_PATHS:+$MISE_IGNORED_CONFIG_PATHS:}$repo_root" \
				mise --no-config bin-paths "$@" </dev/null 2>/dev/null | paste -sd: -
		) || pinned_paths=""
		if [ -n "$pinned_paths" ]; then
			PATH="$pinned_paths:$PATH"
			export PATH
		fi
	fi
}

# check_tool_version <tool> <expected> <version_arg> <sed_expr> [install_hint]
check_tool_version() {
	local tool="$1"
	local expected="$2"
	local version_arg="$3"
	local sed_expr="$4"
	local install_hint="${5:-run: mise install}"
	local out actual
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "mise-tool: $tool not found (expected $expected; $install_hint)" >&2
		exit 1
	fi
	if ! out=$("$tool" "$version_arg" 2>&1); then
		echo "mise-tool: failed to run $tool $version_arg (expected $expected):" >&2
		printf '%s\n' "$out" >&2
		exit 1
	fi
	actual=$(printf '%s\n' "$out" | sed -n "$sed_expr" | sed -n '1p')
	if [ "$actual" != "$expected" ]; then
		echo "mise-tool: $tool version mismatch: expected $expected, got ${actual:-unknown} ($install_hint)" >&2
		exit 1
	fi
}

_mise_tool_main() {
	local cmd="${1:-}"
	local tool="${2:-}"
	if [ "$#" -lt 2 ]; then
		echo "usage: scripts/mise-tool.sh <check|run> <swiftformat|swiftlint> [--] [args...]" >&2
		exit 2
	fi
	shift 2

	local script_dir repo_root mise_config pin version_arg sed_expr hint
	script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
	repo_root=$(cd -- "$script_dir/.." && pwd -P)
	mise_config="$repo_root/$MISE_CONFIG_REL"

	case "$tool" in
	swiftformat)
		pin=$(parse_mise_pin "$mise_config" swiftformat)
		version_arg='--version'
		sed_expr='s/^[[:space:]]*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)[[:space:]]*$/\1/p'
		hint="install via 'mise install' or ${SWIFTFORMAT_RELEASE_URL_PREFIX}${pin}"
		;;
	swiftlint)
		pin=$(parse_mise_pin "$mise_config" swiftlint)
		version_arg='version'
		sed_expr='s/^[[:space:]]*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)[[:space:]]*$/\1/p'
		hint="install via 'mise install' or ${SWIFTLINT_RELEASE_URL_PREFIX}${pin}"
		;;
	*)
		echo "mise-tool: unsupported tool: $tool" >&2
		exit 2
		;;
	esac

	prepend_pinned_mise_paths "$repo_root" "${tool}@${pin}"
	check_tool_version "$tool" "$pin" "$version_arg" "$sed_expr" "$hint"

	case "$cmd" in
	check)
		if [ "$#" -ne 0 ]; then
			echo "mise-tool: check accepts no extra arguments" >&2
			exit 2
		fi
		;;
	run)
		if [ "${1:-}" = "--" ]; then
			shift
		fi
		exec "$tool" "$@"
		;;
	*)
		echo "mise-tool: unsupported command: $cmd" >&2
		exit 2
		;;
	esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	_mise_tool_main "$@"
fi
