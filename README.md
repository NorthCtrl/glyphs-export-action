# Glyphs Export

A GitHub Action that exports fonts from [Glyphs](https://glyphsapp.com) sources
with [glyphs-cli](https://pypi.org/project/glyphs-cli/) on a macOS runner.

It installs glyphs-cli and the Glyphs version you ask for, exports your
`.glyphs` or `.glyphspackage` files, and fails the step if any instance fails.
Uploading the fonts is up to you.

## Usage

```yaml
jobs:
  fonts:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v7

      - uses: NorthCtrl/glyphs-export-action@v0
        id: export
        with:
          glyphs-version: "3536"
          sources: MyFont.glyphspackage

      - uses: actions/upload-artifact@v7
        with:
          name: fonts
          path: ${{ steps.export.outputs.output-dir }}
```

## Choosing the Glyphs version

`glyphs-version` takes one of:

| Value | Meaning |
| --- | --- |
| `3536` | Exactly Glyphs build 3536. Reproducible. |
| `3` or `4` | The newest stable build of Glyphs 3 or Glyphs 4 when the job runs. |
| `3.5.1` | The newest stable build with that version number. |
| `4.1.1-4108` | Exactly Glyphs 4 build 4108. Reproducible, see below. |

`3` and `4` follow Glyphs releases, so the same commit can give different fonts
next month. **Pin a build for releases.** The build that was used is in the
`glyphs-build` output and in a notice on the run.

There is no `latest`: Glyphs 3 and Glyphs 4 differ a lot, and a run should not
move from one to the other on its own. Glyphs 4 opens Glyphs 3 files, but
Glyphs 3 cannot open files saved in the Glyphs 4 file format.

### Glyphs 4

glyphs-cli 0.7.0 cannot install Glyphs 4 yet: its list of versions stops at
Glyphs 3. Until it can, this action downloads Glyphs 4 from Glyphs' own update
server. That works for `4` and for a pinned build written with its version
number, like `4.1.1-4108` (the name of the Glyphs download). A bare Glyphs 4
build number such as `4108` does not work yet. A pinned Glyphs 4 build only
works while Glyphs still offers its download.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `glyphs-version` | (required) | Which Glyphs to export with, see above. |
| `sources` | | Source files, one path or glob per line. Can be empty when `config` names them. |
| `output-dir` | `fonts` | Folder for the fonts. Created if missing. |
| `format` | | `cff`, `tt` or `cff,tt`. Empty: CFF for static fonts, TrueType for variable fonts. |
| `container` | | `standard`, `woff`, `woff2`, or several separated by commas. Empty: `standard`. |
| `config` | | A glyphs-cli [export config file](https://pypi.org/project/glyphs-cli/) (JSON5), to choose instances and settings. |
| `plugins` | | Glyphs plug-ins to load, one per line: a path to a plug-in, or the name of one that comes with Glyphs. |

## Outputs

| Output | Description |
| --- | --- |
| `glyphs-build` | The Glyphs build used, for example `3536`. |
| `glyphs-display-version` | Its version number, for example `3.5.1`. |
| `fonts` | The exported files, one absolute path per line. |
| `output-dir` | The absolute path of the output folder. |

## Plug-ins

If your instances use a filter plug-in, for example a *Filter* custom parameter
set to `UnnestComponents`, fetch the plug-in and pass its path. Pin it to a commit
so your builds stay the same:

```yaml
      - name: Get UnnestComponents
        run: |
          git clone --quiet https://github.com/mekkablue/UnnestComponents.git "$RUNNER_TEMP/UnnestComponents"
          git -C "$RUNNER_TEMP/UnnestComponents" checkout --quiet 20e813a5c53ba2ef940f2af3729bd6a00085107f

      - uses: NorthCtrl/glyphs-export-action@v0
        with:
          glyphs-version: "3536"
          sources: MyFont.glyphspackage
          plugins: ${{ runner.temp }}/UnnestComponents/UnnestComponents.glyphsFilter
```

Python plug-ins get Python 3.12 with `pyobjc-core` and `pyobjc-framework-Cocoa`,
which is what the Glyphs Python API needs. A plug-in that imports other modules
will fail to load.

## What it does

1. Fails straight away if the runner is not macOS.
2. Sets up Python 3.12 without changing the `python` your other steps use, and
   installs the pinned glyphs-cli and pyobjc versions from
   [`requirements.txt`](requirements.txt).
3. Installs the full Glyphs app into the runner's temporary folder. A second use
   of the action in the same job with the same `glyphs-version` reuses it. The
   download takes a few seconds, so there is no cache.
4. Registers the app with macOS, so the system knows the Glyphs file types.
5. Runs `glyphs export` and reads its report. The step fails if glyphs-cli fails,
   if any instance has an error, or if no font was exported. Warnings show up as
   annotations.

## Licence for Glyphs

glyphs-cli runs Glyphs code, which needs a Glyphs licence. According to the
Glyphs team, the CLI is covered by your Glyphs app licence, and no licence file
has to be installed on the runner
([forum](https://forum.glyphsapp.com/t/command-line-tool-for-glyphs/36022/87)).

## Known issues

- **"Failed reading font" on GitHub runners.** glyphs-cli cannot read a source
  until macOS knows the Glyphs file types, which happens when the app is
  registered. An app copied to `/Applications` is registered a little later, so
  an export straight after installing fails at random. This action registers the
  app itself before exporting, so it does not retry.
- **glyphs-cli exits 0 when instances fail**, for example when a filter plug-in
  is missing. This action reads the report and fails the step instead.
- **Glyphs 3 skips CFF variable fonts** with a warning. Glyphs 4 exports them.
- **Same file name for CFF and TrueType WOFF files.** With `format: cff,tt` and a
  WOFF container, both outlines are written to the same `.woff2` name and the
  second wins. Export the two formats in separate steps if you need both.
- **An unknown `format` value crashes glyphs-cli** instead of printing an error.

## Licence

TODO: to be decided before this repository is made public.
