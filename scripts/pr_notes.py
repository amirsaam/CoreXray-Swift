#!/usr/bin/env python3
"""Build the upstream-notes section of a core-update PR body.

Reads raw upstream release notes from a file, strips the sponsor/donation
boilerplate Xray-core appends below its changelog, and prints a markdown
section to stdout: an auto-translated English rendering first (best effort,
via the public translate endpoint), with the original collapsed in a
<details> block after it. Anything already in English goes in untouched.
Never fails loudly: translation trouble degrades to the original text with
a one-line notice, so the workflow always has a PR body to publish.
"""

import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request

CJK = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff]")
BOILERPLATE = re.compile(r"^## Sponsors\s*$", re.MULTILINE)
TRANSLATE_URL = "https://translate.googleapis.com/translate_a/single?client=gtx"


def translate(text: str) -> str | None:
    # One request for the whole note: fewer requests means fewer 429s from
    # the public endpoint. Retries with backoff, then give up softly — the
    # caller prints the original instead.
    for wait in (5, 15, 30):
        try:
            data = urllib.parse.urlencode(
                {"sl": "auto", "tl": "en", "dt": "t", "q": text}
            ).encode()
            request = urllib.request.Request(
                TRANSLATE_URL, data=data, headers={"User-Agent": "Mozilla/5.0"}
            )
            with urllib.request.urlopen(request, timeout=20) as response:
                payload = json.load(response)
            return "".join(segment[0] for segment in payload[0] if segment[0])
        except Exception:
            time.sleep(wait)
    return None


def main() -> int:
    notes = open(sys.argv[1], encoding="utf-8").read().strip()
    src = os.environ.get("SRC", "upstream")
    tag = os.environ.get("TAG", "")

    parts = BOILERPLATE.split(notes, maxsplit=1)
    head = parts[0].strip() or notes

    print(
        "Upstream {0} release notes for {1} follow — read them to decide".format(
            src, tag
        )
    )
    print("whether the Swift layer needs changes before release.")
    print()

    english = translate(head) if CJK.search(head) else head
    if english is None:
        print("> Auto-translation unavailable; original below.")
        print()
        print(head)
    elif english == head:
        print(head)
    else:
        print("> Auto-translated to English below; the original is collapsed after it.")
        print()
        print(english)
        print()
        print("<details>")
        print("<summary>Original ({0})</summary>".format(src))
        print()
        print(head)
        print()
        print("</details>")
    return 0


if __name__ == "__main__":
    sys.exit(main())
