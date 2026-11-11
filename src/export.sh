#!/usr/bin/env bash
# Installs the requested Glyphs version and exports fonts with glyphs-cli.
# Called by action.yml; the inputs arrive as environment variables.
# Written for the bash 3.2 that ships with macOS.
#
# Inputs: PYTHON, GLYPHS_VERSION, SOURCES, OUTPUT_DIR, FORMAT, CONTAINER, CONFIG, PLUGINS.
# shellcheck disable=SC2153 # they are set by action.yml, not misspelled locals
set -eo pipefail

action_dir=$(cd "$(dirname "$0")/.." && pwd)
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

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

# Fallback for Glyphs 4: glyphs-cli 0.7.0 cannot install it because its version
# index lists only Glyphs 2 and 3. This downloads the app from Glyphs' own update
# server instead. Remove it once `glyphs version list --remote 4` shows 4.x builds.
install_from_glyphs_feed() {
	local version=$1 dir=$2 url
	case "$version" in
	4)
		url=$(curl -fsSL --retry 3 https://updates.glyphsapp.com/appcast4.xml | "$PYTHON" -I -c '
import sys, xml.etree.ElementTree as ET
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
stable = [i for i in ET.parse(sys.stdin).iter("item") if i.find("sparkle:channel", ns) is None]
newest = max(stable, key=lambda i: int(i.findtext("sparkle:version", namespaces=ns)))
print(newest.find("enclosure").get("url"))')
		;;
	4.*-*) url="https://updates.glyphsapp.com/Glyphs$version.zip" ;;
	4*) fail "glyphs-cli cannot install Glyphs 4 builds yet. Pin a Glyphs 4 build with its display version, for example 4.1.1-4108, or use 4 for the newest stable Glyphs 4." ;;
	*) fail "No Glyphs version matches '$version'. Run 'glyphs version list --remote' to see the versions glyphs-cli knows." ;;
	esac
	echo "Downloading $url"
	curl -fSL --retry 3 --progress-bar -o "$dir/glyphs.zip" "$url" ||
		fail "Could not download $url. Is $version a Glyphs version that exists?"
	ditto -x -k "$dir/glyphs.zip" "$dir"
	rm "$dir/glyphs.zip"
}

# Check the inputs before installing anything.

version_pattern='^[0-9]+(\.[0-9]+)*(-[0-9]+)?$'
[[ $GLYPHS_VERSION =~ $version_pattern ]] ||
	fail "glyphs-version '$GLYPHS_VERSION' is not a Glyphs version. Use a build such as 3536, a major version such as 3 or 4, or a pinned Glyphs 4 build such as 4.1.1-4108."

sources=()
default_ifs=$IFS
shopt -s nullglob
while IFS= read -r pattern; do
	# Unquoted on purpose so globs expand; an empty IFS keeps paths with spaces whole.
	IFS=
	# shellcheck disable=SC2206
	matches=($pattern)
	IFS=$default_ifs
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

# Install glyphs-cli, and pyobjc for Glyphs' Python API and Python plug-ins.

"$PYTHON" -m pip install --quiet --disable-pip-version-check --requirement "$action_dir/requirements.txt"
glyphs="$(dirname "$PYTHON")/glyphs"
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
	# glyphs-cli can install this version if its index has any build of the same
	# major. Rows for builds already installed show a path instead of <remote>.
	major=${GLYPHS_VERSION%%[.-]*}
	remote=$("$glyphs" version list --remote --plain --no-header "$major" | awk -F '\t' '$3 == "<remote>"')
	if [ -n "$remote" ]; then
		"$glyphs" version install --app --output "$install_dir" "${GLYPHS_VERSION##*-}"
	else
		install_from_glyphs_feed "$GLYPHS_VERSION" "$install_dir"
	fi
	app=$(find_app "$install_dir")
	[ -n "$app" ] || fail "Installing Glyphs $GLYPHS_VERSION did not produce an app in $install_dir."
	echo "::endgroup::"
fi

# Register the app with Launch Services, so macOS knows the .glyphs and
# .glyphspackage file types. Without this, glyphs-cli fails with
# "Failed reading font", every time on a fresh runner.
"$lsregister" -f "$app"

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
"$glyphs" "${args[@]}" || status=$?

# glyphs-cli exits 0 even when instances fail, so the report decides.
{
	echo "glyphs-build=$build"
	echo "glyphs-display-version=$display_version"
	echo "output-dir=$output_dir"
} >>"$GITHUB_OUTPUT"
"$PYTHON" -I "$action_dir/src/report.py" "$report" "$status"
