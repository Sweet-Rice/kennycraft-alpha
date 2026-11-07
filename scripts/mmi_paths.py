#!/usr/bin/env python3
"""Resolve updatemem processor paths and word widths from a Vivado MMI file.

    mmi_paths.py kc.mmi imem dmem=<InstPath> tex

Each argument is a memory name, optionally with an explicit InstPath. Without
one, the single InstPath containing the name is used (P3's kc.mmi: imem, dmem,
tex). Prints one "<InstPath> <width>" line per memory, where width is the bit
width of one word: the sum of the DataWidth lanes of its first BusBlock.
"""
import argparse
import re
import sys
import xml.etree.ElementTree as ET


def word_width(processor):
    block = processor.find('./AddressSpace/BusBlock')
    if block is None:
        raise ValueError(f'MMI processor {processor.attrib["InstPath"]} has no BusBlock')
    width = 0
    for lane in block.iter('DataWidth'):
        width += int(lane.attrib['MSB']) - int(lane.attrib['LSB']) + 1
    if width == 0:
        raise ValueError(f'MMI processor {processor.attrib["InstPath"]} has no DataWidth')
    return width


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('mmi')
    parser.add_argument('memories', nargs='+', metavar='NAME[=INSTPATH]')
    args = parser.parse_args()
    try:
        root = ET.parse(args.mmi).getroot()
        processors = {node.attrib['InstPath']: node for node in root.iter('Processor') if 'InstPath' in node.attrib}
        lines = []
        for memory in args.memories:
            name, _, explicit = memory.partition('=')
            if explicit:
                if explicit not in processors:
                    raise ValueError(f'{name} InstPath not in {args.mmi}: {explicit}')
                path = explicit
            else:
                candidates = sorted(path for path in processors if re.search(re.escape(name), path, re.I))
                if len(candidates) != 1:
                    found = ', '.join(sorted(processors)) or 'none'
                    raise ValueError(f'{args.mmi} has no unique {name} processor (InstPaths: {found}); '
                                     f'set {name.upper()}_PROC= to one of them')
                path = candidates[0]
            lines.append(f'{path} {word_width(processors[path])}')
        print('\n'.join(lines))
        return 0
    except (OSError, ET.ParseError, ValueError, KeyError) as error:
        print(f'board: {error}', file=sys.stderr)
        return 5


if __name__ == '__main__':
    sys.exit(main())
