#!/usr/bin/env python3
"""
Prints the ninja targets that compile the files changed by the FacetBrowser
Engine patches, one per line, for github_build.sh to build before anything
else.

usage: facet_preflight.py <engine patches dir> <file with `ninja -t inputs chrome` output>

A patched Blink .idl is represented by the V8 binding generated from it.
Files that are not an input of chrome on this platform are reported on stderr
and left out.
"""

import re
import sys
from pathlib import Path

_PATCH_DIRS = ('extra/fingerprint/', 'extra/facet/')
_SOURCE_SUFFIXES = ('.cc', '.cpp', '.c', '.mm', '.m')


def patched_sources(patches_dir):
    """Translation units touched by the engine's own patches, in series order"""
    sources = []
    for entry in (patches_dir / 'series').read_text(encoding='utf-8').splitlines():
        entry = entry.strip()
        if not entry.startswith(_PATCH_DIRS):
            continue
        for line in (patches_dir / entry).read_text(encoding='utf-8').splitlines():
            if not line.startswith('+++ b/'):
                continue
            path = line[len('+++ b/'):].split('\t')[0].strip()
            idl = re.fullmatch(r'third_party/blink/renderer/(core|modules)/.*/(\w+)\.idl', path)
            if idl:
                path = 'gen/third_party/blink/renderer/bindings/{}/v8/v8_{}.cc'.format(*idl.groups())
            elif path.endswith(_SOURCE_SUFFIXES):
                path = '../../' + path
            else:
                continue
            if path not in sources:
                sources.append(path)
    return sources


def main():
    patches_dir, inputs_file = Path(sys.argv[1]), Path(sys.argv[2])
    known = {line.strip() for line in inputs_file.read_text(encoding='utf-8').splitlines()}
    for source in patched_sources(patches_dir):
        if source in known:
            print(source + '^')
        else:
            print('Preflight: not an input of chrome, skipped: ' + source, file=sys.stderr)


if __name__ == '__main__':
    main()
