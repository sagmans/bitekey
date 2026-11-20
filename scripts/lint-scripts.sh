#!/usr/bin/env bash
# Format-check and lint repo-owned shell and Python scripts at the exact
# versions pinned in mise.toml. Shared by pre-commit (staged snapshot),
# pre-push (pushed tip via Makefile), and `make lint-scripts` so target
# selection, flags, and tool pins never drift.
# Usage:
#   scripts/lint-scripts.sh [--] [paths...]   # check all tracked scripts or given paths
#   scripts/lint-scripts.sh --filter          # filter NUL-delimited repo-relative paths on stdin
set -euo pipefail

# Explicit isolated Ruff rules so host user configs cannot alter hook results.
# E501 is omitted because ruff format owns wrapping and long SVG/log strings stay intact.
readonly RUFF_SELECT='E,F,W,I,B,UP,EXE'
readonly RUFF_IGNORE='E501'
# Git hooks and command-line tools often have no language suffix.
readonly INTERPRETER_PREFIX='^[[:blank:]]*([^[:blank:]]*/)?(env[[:blank:]]+(-S[[:blank:]]+)?)?([^[:blank:]]*/)?'
readonly SHELL_INTERPRETER="${INTERPRETER_PREFIX}(sh|bash|dash|ksh|mksh)([[:space:]]|$)"
readonly PYTHON_INTERPRETER="${INTERPRETER_PREFIX}(uv[[:blank:]]+run[[:blank:]]+([^[:blank:]]+[[:blank:]]+)*)?python([0-9]+(\.[0-9]+)*)?([[:space:]]|$)"

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)

# Single authority for repo-owned shell and Python script classification.
classify_rel_path() {
	local lower marker interpreter file="$repo_root/$1"
	lower=$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')
	case "$lower" in
	scripts/setup-hooks | .githooks/lib/* | .githooks/pre-commit | .githooks/pre-merge-commit | .githooks/prepare-commit-msg | .githooks/commit-msg | .githooks/pre-push)
		return 1
		;;
	*.py)
		printf 'python\n'
		return 0
		;;
	*.sh | *.bash)
		printf 'shell\n'
		return 0
		;;
	esac

	# Read from the tree that owns this helper. During a partial commit the
	# caller's working directory can contain a different interpreter or no file.
	case "/$1/" in */../* | //*) return 1 ;; esac
	[ -f "$file" ] && [ ! -L "$file" ] || return 1
	{
		IFS= LC_ALL=C read -r -n 2 marker || return 1
		[ "$marker" = '#!' ] || return 1
		IFS= LC_ALL=C read -r -n 253 interpreter || :
	} <"$file"
	if [[ $interpreter =~ $SHELL_INTERPRETER ]]; then
		printf 'shell\n'
	elif [[ $interpreter =~ $PYTHON_INTERPRETER ]]; then
		printf 'python\n'
	else
		return 1
	fi
}

if [ "${1:-}" = "--filter" ]; then
	if [ "$#" -ne 1 ]; then
		echo "lint-scripts: --filter accepts no extra arguments" >&2
		exit 2
	fi
	while IFS= read -r -d '' path; do
		if classify_rel_path "$path" >/dev/null; then
			printf '%s\0' "$path"
		fi
	done
	exit 0
fi

case "${1:-}" in
--)
	shift
	;;
-*)
	echo "lint-scripts: unknown option: $1" >&2
	exit 2
	;;
esac

# shellcheck source-path=SCRIPTDIR source=./mise-tool.sh
. "$script_dir/mise-tool.sh"
mise_config="$repo_root/$MISE_CONFIG_REL"

normalize_explicit_path() {
	local raw="$1"
	local dir base abs
	if [ -L "$raw" ]; then
		echo "lint-scripts: refusing symlink target: $raw" >&2
		exit 1
	fi
	if [ ! -f "$raw" ]; then
		echo "lint-scripts: target file not found: $raw" >&2
		exit 1
	fi
	dir=$(dirname -- "$raw")
	base=$(basename -- "$raw")
	abs="$(cd -- "$dir" && pwd -P)/$base"
	case "$abs" in
	"$repo_root"/*)
		printf '%s\n' "${abs#"$repo_root/"}"
		;;
	*)
		echo "lint-scripts: path outside repository root ($repo_root): $raw" >&2
		exit 1
		;;
	esac
}

shell_files=()
python_files=()

if [ "$#" -eq 0 ]; then
	cd "$repo_root"
	ls_file=$(mktemp "${TMPDIR:-/tmp}/sweetmx-lint-ls.XXXXXX")
	cleanup_ls() {
		case "$ls_file" in
		*/sweetmx-lint-ls.*) rm -f -- "$ls_file" ;;
		esac
	}
	trap cleanup_ls EXIT
	trap 'exit 129' HUP
	trap 'exit 130' INT
	trap 'exit 143' TERM
	git -C "$repo_root" ls-files --stage -z >"$ls_file"
	while IFS= read -r -d '' entry; do
		mode=${entry%% *}
		path=${entry#*	}
		case "$mode" in
		100644 | 100755) ;;
		*) continue ;;
		esac
		[ -f "$path" ] && [ ! -L "$path" ] || continue
		if kind=$(classify_rel_path "$path"); then
			case "$kind" in
			python) python_files+=("$path") ;;
			shell) shell_files+=("$path") ;;
			esac
		fi
	done <"$ls_file"
	cleanup_ls
	trap - EXIT HUP INT TERM
	if [ "${#shell_files[@]}" -eq 0 ] && [ "${#python_files[@]}" -eq 0 ]; then
		echo "lint-scripts: no tracked repo shell or Python scripts found" >&2
		exit 1
	fi
else
	for arg in "$@"; do
		rel=$(normalize_explicit_path "$arg")
		if ! kind=$(classify_rel_path "$rel"); then
			echo "lint-scripts: unsupported or excluded target path: $arg" >&2
			exit 1
		fi
		case "$kind" in
		python) python_files+=("$rel") ;;
		shell) shell_files+=("$rel") ;;
		esac
	done
	cd "$repo_root"
fi

pin_specs=()
sc_pin=""
shfmt_pin=""
ruff_pin=""

if [ "${#shell_files[@]}" -gt 0 ]; then
	sc_pin=$(parse_mise_pin "$mise_config" shellcheck)
	shfmt_pin=$(parse_mise_pin "$mise_config" shfmt)
	pin_specs+=("shellcheck@$sc_pin" "shfmt@$shfmt_pin")
fi
if [ "${#python_files[@]}" -gt 0 ]; then
	ruff_pin=$(parse_mise_pin "$mise_config" ruff)
	pin_specs+=("ruff@$ruff_pin")
fi

prepend_pinned_mise_paths "$repo_root" "${pin_specs[@]}"

if [ "${#shell_files[@]}" -gt 0 ]; then
	check_tool_version shellcheck "$sc_pin" '--version' 's/^version: *//p'
	check_tool_version shfmt "$shfmt_pin" '--version' 's/^v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$/\1/p'

	shellcheck -x -- "${shell_files[@]}"
	shfmt -d -- "${shell_files[@]}"
fi

if [ "${#python_files[@]}" -gt 0 ]; then
	check_tool_version ruff "$ruff_pin" '--version' 's/^ruff \([^[:space:]]*\).*/\1/p'

	ruff format --isolated --no-cache --check --diff -- "${python_files[@]}"
	ruff check --isolated --no-cache --select "$RUFF_SELECT" --ignore "$RUFF_IGNORE" -- "${python_files[@]}"
fi
