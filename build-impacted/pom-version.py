#!/usr/bin/env python3
"""Print the root <version> of a pom, without any -SNAPSHOT suffix.

Usage: pom-version.py POM

Reads the pom directly: `mvn help:evaluate -q` does not strip every [INFO] line on Maven 4.
The namespace is detected (Model 4.0.0 or 4.1.0, or none).
"""
import re
import sys
import xml.etree.ElementTree as ET


def base_version(path):
    root = ET.parse(path).getroot()
    ns = root.tag[1:].split("}", 1)[0] if root.tag.startswith("{") else ""
    v = root.find(f"{{{ns}}}version") if ns else root.find("version")
    if v is None or not v.text:
        raise ValueError("root <version> not found")
    return re.sub(r"-SNAPSHOT$", "", v.text.strip())


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.stderr.write(__doc__)
        sys.exit(2)
    try:
        print(base_version(sys.argv[1]))
    except (OSError, ET.ParseError, ValueError) as e:
        sys.stderr.write(f"{e}\n")
        sys.exit(1)
