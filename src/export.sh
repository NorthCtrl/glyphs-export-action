#!/usr/bin/env bash
# Installs the requested Glyphs version and exports fonts with glyphs-cli.
# Called by action.yml; the inputs arrive as environment variables.
# Written for the bash 3.2 that ships with macOS.
#
# Inputs: PYTHON, GLYPHS_VERSION, SOURCES, OUTPUT_DIR, FORMAT, CONTAINER, CONFIG, PLUGINS.
# shellcheck disable=SC2153 # they are set by action.yml, not misspelled locals
set -eo pipefail

action_dir=$(cd "$(dirname "$0")/.." && pwd)

fail() {
	echo "::error::$*"
	exit 1
}

# Prints each non-empty line of $1 without surrounding whitespace.
lines() {
	local line
	while IFS= read -r line; do
		line="${line#"${line%%[![:space:]]*}"}"
		line="${line%"${line##*[![:space:]]}"}"
		if [ -n "$line" ]; then printf '%s\n' "$line"; fi
	done <<<"$1"
}

absolute_path() {
	printf '%s/%s\n' "$(cd "$(dirname "$1")" && pwd)" "$(basename "$1")"
}

find_app() {
	if [ -d "$1" ]; then find "$1" -maxdepth 1 -name '*.app' | head -n 1; fi
}

# Check the inputs before installing anything.

version_pattern='^[0-9]+(\.[0-9]+)*$'
[[ $GLYPHS_VERSION =~ $version_pattern ]] ||
	fail "glyphs-version '$GLYPHS_VERSION' is not a Glyphs version. Use a build such as 3536, a major version such as 3 or 4, or a version number such as 3.5.1."

sources=()
default_ifs=$IFS
shopt -s nullglob
while IFS= read -r pattern; do
	if [ -e "$pattern" ]; then
		# An existing path is taken as it is, so names like MyFont[wght].glyphs work.
		matches=("$pattern")
	else
		# Unquoted on purpose so globs expand; an empty IFS keeps paths with spaces whole.
		IFS=
		# shellcheck disable=SC2206
		matches=($pattern)
		IFS=$default_ifs
	fi
	[ ${#matches[@]} -gt 0 ] || fail "No source file matches '$pattern'."
	for match in "${matches[@]}"; do
		[ -e "$match" ] || fail "Source file '$match' does not exist."
		sources+=("$match")
	done
done < <(lines "$SOURCES")
shopt -u nullglob

if [ -n "$CONFIG" ] && [ ! -f "$CONFIG" ]; then
	fail "Config file '$CONFIG' does not exist."
fi
if [ ${#sources[@]} -eq 0 ] && [ -z "$CONFIG" ]; then
	fail "Set sources to one or more .glyphs or .glyphspackage files, or name them in a config file."
fi

plugins=""
while IFS= read -r plugin; do
	case "$plugin" in *,*) fail "Plug-in '$plugin' has a comma in its name, which glyphs-cli cannot handle." ;; esac
	# A path that exists is a plug-in bundle; anything else is the name of a built-in plug-in.
	if [ -e "$plugin" ]; then plugin=$(absolute_path "$plugin"); fi
	plugins="${plugins:+$plugins,}$plugin"
done < <(lines "$PLUGINS")

mkdir -p "$OUTPUT_DIR"
output_dir=$(cd "$OUTPUT_DIR" && pwd)

# Install glyphs-cli, and pyobjc for Glyphs' Python API and Python plug-ins, into a
# folder of their own, so the Python that other steps use stays as it was.
# PYTHONPATH also reaches the Python that Glyphs runs plug-ins in.

packages="${RUNNER_TEMP:?}/glyphs-export-action/python-packages"
if [ ! -d "$packages" ]; then
	"$PYTHON" -m pip install --quiet --disable-pip-version-check --target "$packages" --requirement "$action_dir/requirements.txt"
fi
export PYTHONPATH="$packages"
glyphs() {
	"$PYTHON" -P -c 'import glyphs_cli; glyphs_cli.main()' "$@"
}
python_framework="$("$PYTHON" -c 'import sys; print(sys.base_prefix)')/Python"
[ -f "$python_framework" ] || fail "Python at $PYTHON is not a framework build; Glyphs needs one."

# Install the full Glyphs app into a folder of its own, so a later call in the same
# job can reuse it. Python plug-ins need the full app: the smaller default install
# leaves out the GlyphsApp Python module.

install_dir="${RUNNER_TEMP:?}/glyphs-export-action/glyphs-$GLYPHS_VERSION"
app=$(find_app "$install_dir")
if [ -z "$app" ]; then
	echo "::group::Install Glyphs $GLYPHS_VERSION"
	mkdir -p "$install_dir"
	glyphs version install --app --output "$install_dir" "$GLYPHS_VERSION" ||
		fail "glyphs-cli could not install Glyphs $GLYPHS_VERSION; see the log."
	app=$(find_app "$install_dir")
	[ -n "$app" ] || fail "Installing Glyphs $GLYPHS_VERSION did not produce an app in $install_dir."
	echo "::endgroup::"
fi

# Check that the app is signed by Glyphs' developer, Georg Seifert (Apple team
# X2L8375ZQ7), and unchanged since it was signed.
codesign --verify --deep --strict \
	-R='anchor apple generic and certificate leaf[subject.OU] = "X2L8375ZQ7"' "$app" ||
	fail "$app is not signed by Glyphs' developer, or has changed since it was signed."

# Read the version from the app itself: `glyphs version resolve` takes the build
# from the file name, so "Glyphs 3.5.1-3536.app" gives "3536.app".
display_version=$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")
build=$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")
echo "::notice title=Glyphs version::Exporting with Glyphs $display_version ($build), selected by glyphs-version '$GLYPHS_VERSION'."

# Export.

report="${RUNNER_TEMP}/glyphs-export-action/report-$$.jsonl"
rm -f "$report"
args=(export --app "$app" --python "$python_framework" --output "$output_dir" --json-output "$report")
if [ -n "$FORMAT" ]; then args+=(--format "$FORMAT"); fi
if [ -n "$CONTAINER" ]; then args+=(--container "$CONTAINER"); fi
if [ -n "$CONFIG" ]; then args+=(--config "$CONFIG"); fi
if [ -n "$plugins" ]; then args+=(--plugins "$plugins"); fi
if [ ${#sources[@]} -gt 0 ]; then args+=("${sources[@]}"); fi

printf 'Running: glyphs'
printf ' %q' "${args[@]}"
echo
status=0
glyphs "${args[@]}" || status=$?

# The report gives the `fonts` output and an annotation for each problem.
{
	echo "glyphs-build=$build"
	echo "glyphs-display-version=$display_version"
	echo "output-dir=$output_dir"
} >>"$GITHUB_OUTPUT"
"$PYTHON" -I "$action_dir/src/report.py" "$report" "$status"
