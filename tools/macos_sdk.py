#!/usr/bin/env python3
"""Choose an installed SDK whose SwiftUI State can compile with this toolchain."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def compatible(sdk):
    source = 'import SwiftUI\nstruct SDKProbe { @State private var value = false }\n'
    with tempfile.TemporaryDirectory(prefix='squirrel-sdk-probe-') as directory:
        path = Path(directory) / 'Probe.swift'
        path.write_text(source)
        result = subprocess.run(['xcrun', 'swiftc', '-typecheck', '-sdk', str(sdk),
                                 str(path)], capture_output=True, timeout=90)
    return result.returncode == 0


def select_sdk():
    selected = Path(subprocess.check_output(
        ['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()).resolve()
    explicit = os.environ.get('ENHANCEMENT_SDK_PATH')
    candidates = [Path(explicit).resolve()] if explicit else [selected]
    if not explicit:
        # Command Line Tools may ship a newer SDK before its SwiftUI macro
        # plugin. Probe other installed SDKs, without changing xcode-select.
        others = sorted(selected.parent.glob('MacOSX*.sdk'), reverse=True)
        candidates.extend(path.resolve() for path in others)
    visited = set()
    for sdk in candidates:
        if sdk in visited or not sdk.is_dir():
            continue
        visited.add(sdk)
        if compatible(sdk):
            if sdk != selected:
                print('SwiftUI SDK compatibility fallback: ' + sdk.name,
                      file=sys.stderr)
            return str(sdk)
    raise RuntimeError('No installed SDK can compile SwiftUI @State. Install a '
                       'matching Xcode/Command Line Tools, or set '
                       'ENHANCEMENT_SDK_PATH to a compatible SDK.')


if __name__ == '__main__':
    try:
        print(select_sdk())
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(2)
