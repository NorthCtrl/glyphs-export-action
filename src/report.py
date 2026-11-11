"""Turn the glyphs-cli JSON Lines report into annotations and the `fonts` output.

Usage: report.py REPORT EXIT_STATUS

Exits non-zero when glyphs-cli failed, when any instance reported an error,
or when no font was exported. glyphs-cli itself exits 0 when instances fail.
"""

import json
import os
import sys


def escape_data(text):
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def escape_property(text):
    return escape_data(text).replace(":", "%3A").replace(",", "%2C")


def annotate(level, report, problem):
    source = os.path.basename(report.get("sourceFilePath") or "")
    title = f"{source} {report.get('instanceName') or ''}".strip()
    message = problem.get("description") or problem.get("title") or "No details given."
    print(f"::{level} title={escape_property(title)}::{escape_data(message)}")


def main(report_path, status):
    reports = []
    if os.path.exists(report_path):
        with open(report_path, encoding="utf-8") as file:
            for line in file:
                try:
                    reports.append(json.loads(line))
                except json.JSONDecodeError:
                    if line.strip():
                        print(f"::warning::Could not read a line of the glyphs-cli report: {escape_data(line.strip())}")

    fonts = []
    errors = 0
    for report in reports:
        for warning in report.get("warnings") or []:
            annotate("warning", report, warning)
        for error in report.get("errors") or []:
            annotate("error", report, error)
            errors += 1
        if report.get("exportFilePath") and not report.get("errors"):
            fonts.append(report["exportFilePath"])

    # Exporting both outlines to WOFF names both files alike, so the second
    # replaces the first; list such a path once.
    fonts = list(dict.fromkeys(fonts))

    delimiter = f"EOF_{os.urandom(8).hex()}"
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write(f"fonts<<{delimiter}\n")
        output.writelines(f"{font}\n" for font in fonts)
        output.write(f"{delimiter}\n")

    print(f"Exported {len(fonts)} font files:")
    for font in fonts:
        print(f"  {font}")

    if status != 0:
        print(f"::error::glyphs export failed with exit status {status}. See the log above.")
        return 1
    if errors:
        print(f"::error::glyphs export reported {errors} error(s). See the annotations.")
        return 1
    if not fonts:
        print("::error::glyphs export finished without exporting any fonts. Do the sources have active instances?")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], int(sys.argv[2])))
