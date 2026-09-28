#!/usr/bin/env python3
"""Count posts in the Firestore emulator, correctly.

Read-only, and deliberately so: three other agents are working against this
emulator and the seeded data must not be touched.

Why this is not a one-line curl: the emulator's REST `list` honours its own page
cap regardless of `pageSize`. Asking for 1000 returns 150 when there are 210,
with a `nextPageToken` that a naive caller never looks at. The first version of
the preflight did exactly that and reported the dataset as wrong — which, had
anyone believed it, would have led to reseeding a database other people were
mid-run against.

`Authorization: Bearer owner` bypasses the security rules. Without it the
emulator applies firestore.rules to REST reads too, and several collections
answer 403 to a plain list.
"""

import json
import sys
import urllib.error
import urllib.request

HOST = "127.0.0.1:8088"
PROJECT = "petnote-test"
BASE = f"http://{HOST}/v1/projects/{PROJECT}/databases/(default)/documents"


def list_all(collection, mask="createdAt"):
    token, names = None, []
    while True:
        url = f"{BASE}/{collection}?pageSize=300&mask.fieldPaths={mask}"
        if token:
            url += f"&pageToken={token}"
        request = urllib.request.Request(url, headers={"Authorization": "Bearer owner"})
        payload = json.load(urllib.request.urlopen(request, timeout=15))
        names += [d["name"].split("/")[-1] for d in payload.get("documents", [])]
        token = payload.get("nextPageToken")
        if not token:
            return names


def main():
    try:
        posts = list_all("posts")
    except (urllib.error.URLError, OSError) as error:
        print(f"0  # emulator unreachable: {error}", file=sys.stderr)
        print(0)
        return 1
    if "--detail" in sys.argv:
        print(f"posts={len(posts)}")
        print(f"first={min(posts)} last={max(posts)}")
        return 0
    print(len(posts))
    return 0


if __name__ == "__main__":
    sys.exit(main())
