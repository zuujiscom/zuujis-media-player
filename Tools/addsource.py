#!/usr/bin/env python3
"""Registers new Swift files in project.pbxproj (the project has no synchronized groups).
usage: addsource.py <group-sibling-file> <relative/path/New.swift> ...
The sibling is an existing file in the same group, used to find the group and build phase."""
import re, sys, random
p = 'ZuujisMediaPlayer.xcodeproj/project.pbxproj'
s = open(p).read()
sibling = sys.argv[1]
for path in sys.argv[2:]:
    name = path.split('/')[-1]
    if name + ' */' in s and f'path = {name};' in s:
        continue
    used = set(re.findall(r'\b[0-9A-F]{24}\b', s))
    def new_id():
        while True:
            i = ''.join(random.choice('0123456789ABCDEF') for _ in range(24))
            if i not in used:
                used.add(i); return i
    fref, bref = new_id(), new_id()
    sib_ref = re.search(r'([0-9A-F]{24}) /\* ' + re.escape(sibling) + r' \*/ = \{isa = PBXFileReference', s).group(1)
    sib_build = re.search(r'([0-9A-F]{24}) /\* ' + re.escape(sibling) + r' in Sources \*/ = \{isa = PBXBuildFile', s).group(1)
    s = s.replace('/* Begin PBXBuildFile section */\n', f'/* Begin PBXBuildFile section */\n\t\t{bref} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fref} /* {name} */; }};\n', 1)
    s = s.replace('/* Begin PBXFileReference section */\n', f'/* Begin PBXFileReference section */\n\t\t{fref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};\n', 1)
    s = re.sub(r'(\t+)' + sib_ref + r' /\* ' + re.escape(sibling) + r' \*/,\n', lambda m: m.group(0) + f'{m.group(1)}{fref} /* {name} */,\n', s, count=1)
    s = re.sub(r'(\t+)' + sib_build + r' /\* ' + re.escape(sibling) + r' in Sources \*/,\n', lambda m: m.group(0) + f'{m.group(1)}{bref} /* {name} in Sources */,\n', s, count=1)
open(p, 'w').write(s)
