#!/usr/bin/env python3
"""Resolve the two updatemem processor paths from an actual Vivado MMI file."""
import argparse
import re
import sys
import xml.etree.ElementTree as ET


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mmi')
    parser.add_argument('--imem', default='')
    parser.add_argument('--dmem', default='')
    args = parser.parse_args()
    try:
        root = ET.parse(args.mmi).getroot()
        paths = {node.attrib['InstPath'] for node in root.iter() if 'InstPath' in node.attrib}
        selected = []
        for name, explicit in [('imem', args.imem), ('dmem', args.dmem)]:
            if explicit:
                if explicit not in paths:
                    raise ValueError(f'{name} InstPath not in MMI: {explicit}')
                selected.append(explicit)
                continue
            candidates = sorted(path for path in paths if re.search(name, path, re.I))
            if len(candidates) != 1:
                raise ValueError(f'MMI has no unique {name} InstPath; set {name.upper()}_PROC= from its InstPath attributes')
            selected.append(candidates[0])
        print('\n'.join(selected))
        return 0
    except (OSError, ET.ParseError, ValueError) as error:
        print(f'board: {error}', file=sys.stderr)
        return 5


if __name__ == '__main__':
    sys.exit(main())
