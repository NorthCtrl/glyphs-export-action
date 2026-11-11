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
# server instead. Remove it, and its use below, once glyphs-cli lists Glyphs 4.
glyphs_cli_lists_glyphs_4() {
	# Rows for Glyphs apps already on the machine show a path, not <remote>.
	[ -n "$(glyphs version list --remote --plain --no-header 4 | awk -F '\t' '$3 == "<remote>"')" ]
}

install_from_glyphs_feed() {
	local version=$1 dir=$2 feed found url signature
	case "$version" in
	4 | 4.*-*) ;;
	*) fail "glyphs-cli cannot install Glyphs 4 yet. Use 4 for the newest stable Glyphs 4, or pin a build with its version number, for example 4.1.1-4108." ;;
	esac
	feed=$(curl -fsSL --retry 3 https://updates.glyphsapp.com/appcast4.xml) ||
		fail "Could not read Glyphs' update feed, https://updates.glyphsapp.com/appcast4.xml."
	found=$(feed_tool find "$version" <<<"$feed") ||
		fail "Could not find Glyphs $version in https://updates.glyphsapp.com/appcast4.xml."
	url=$(sed -n 1p <<<"$found")
	signature=$(sed -n 2p <<<"$found")
	echo "Downloading $url"
	curl -fSL --retry 3 --progress-bar -o "$dir/glyphs.zip" "$url" ||
		fail "Could not download $url. Does Glyphs $version exist?"
	if [ -n "$signature" ]; then
		feed_tool verify "$dir/glyphs.zip" "$signature" ||
			fail "The Glyphs $version download failed its signature check, so it was not installed."
		echo "The download matches its signature in Glyphs' update feed."
	else
		echo "::warning title=Glyphs download::Glyphs' update feed no longer lists $version, so only its Apple code signature can be checked."
	fi
	ditto -x -k "$dir/glyphs.zip" "$dir"
	rm "$dir/glyphs.zip"
}

feed_tool() {
	"$PYTHON" -P "$action_dir/src/glyphs4_feed.py" "$@"
}

# Check the inputs before installing anything.

version_pattern='^[0-9]+(\.[0-9]+)*(-[0-9]+)?$'
[[ $GLYPHS_VERSION =~ $version_pattern ]] ||
	fail "glyphs-version '$GLYPHS_VERSION' is not a Glyphs version. Use a build such as 3536, a major version such as 3 or 4, or a pinned Glyphs 4 build such as 4.1.1-4108."

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
	case "$GLYPHS_VERSION" in
	4 | 4.*) glyphs_cli_lists_glyphs_4 || install_from_glyphs_feed "$GLYPHS_VERSION" "$install_dir" ;;
	esac
	if [ -z "$(find_app "$install_dir")" ]; then
		# The pinned form 3.5.1-3536 is passed on as the build, 3536.
		glyphs version install --app --output "$install_dir" "${GLYPHS_VERSION##*-}" ||
			fail "glyphs-cli could not install Glyphs $GLYPHS_VERSION; see the log. A Glyphs 4 build needs its version number, for example 4.1.1-4108."
	fi
	app=$(find_app "$install_dir")
	[ -n "$app" ] || fail "Installing Glyphs $GLYPHS_VERSION did not produce an app in $install_dir."
	echo "::endgroup::"
fi

# Check that the app is signed by Glyphs' developer, Georg Seifert (Apple team
# X2L8375ZQ7), and unchanged since, whichever way it was downloaded.
codesign --verify --deep --strict \
	-R='anchor apple generic and certificate leaf[subject.OU] = "X2L8375ZQ7"' "$app" ||
	fail "$app is not signed by Glyphs' developer, or has changed since it was signed."

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
glyphs "${args[@]}" || status=$?

# glyphs-cli exits 0 even when instances fail, so the report decides.
{
	echo "glyphs-build=$build"
	echo "glyphs-display-version=$display_version"
	echo "output-dir=$output_dir"
} >>"$GITHUB_OUTPUT"
"$PYTHON" -I "$action_dir/src/report.py" "$report" "$status"
