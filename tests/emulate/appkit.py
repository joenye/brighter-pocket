"""Which selectors the device's AppKit answers: Tolkara's AppKit adapter with this layer.

Read from the prepared tree (tools/prepare.py), so the harness asks exactly what a build
from it would have: each `@implementation`'s methods, each `@property` of an `@interface`
(synthesized), the superclass chain from the `@interface` lines, and what
pocket/translation/AppKit/PocketCompat.m adds at load with class_addMethod. Classes the
client imports from AppKit that the adapter does not define are the platform's stub classes:
they answer NSObject's own methods and nothing else.
"""
from __future__ import annotations

import re
from pathlib import Path

NSOBJECT = {"alloc", "new", "init", "retain", "release", "autorelease", "self", "class", "superclass", "copy",
            "isKindOfClass:", "isMemberOfClass:", "respondsToSelector:", "conformsToProtocol:", "isEqual:", "hash",
            "description", "debugDescription", "performSelector:", "performSelector:withObject:",
            "performSelector:withObject:withObject:", "isProxy", "zone", "retainCount"}
# PocketCompat.m's constructor, which adds these where the class lacks them (checked against
# the source below, so a change there shows up here).
ADDED_AT_LOAD = {("NSCursor", True): {"IBeamCursor", "crosshairCursor", "pointingHandCursor", "operationNotAllowedCursor"},
                 ("NSBitmapImageRep", True): {"imageRepWithData:"}}


def selector_of(signature: str) -> str:
    parts = re.findall(r"(\w+)\s*:", signature)
    return "".join(p + ":" for p in parts) if parts else signature.strip().split()[0]


class AppKitCoverage:
    def __init__(self, tree: Path, imported: set[str]):
        self.methods: dict[tuple[str, bool], set[str]] = {}
        self.superclass: dict[str, str] = {}
        defined: set[str] = set()   # classes the adapter defines (a category on a system class does not)
        sources = sorted((tree / "translation/AppKit").glob("*.[hm]")) + sorted((tree / "translation/AKSupport").glob("*.[hm]"))
        for source in sources:
            text = source.read_text(errors="replace")
            for match in re.finditer(r"@interface\s+(\w+)\s*:\s*(\w+)", text):
                self.superclass.setdefault(match.group(1), match.group(2))
            for block in re.finditer(r"@(implementation|interface)\s+(\w+)\s*(\(\s*\w*\s*\))?(.*?)@end", text, re.S):
                kind, name, category, body = block.groups()
                if kind == "implementation" and not category:
                    defined.add(name)
                for m in re.finditer(r"^\s*([-+])\s*\([^)]*\)\s*([^;{]+)", body, re.M):
                    if kind == "implementation":
                        self.methods.setdefault((name, m.group(1) == "+"), set()).add(selector_of(m.group(2)))
                for p in re.finditer(r"@property\s*(\([^)]*\))?[^;]*?\**\s*(\w+)\s*;", body):
                    attributes, prop = p.group(1) or "", p.group(2)
                    getter = re.search(r"getter\s*=\s*(\w+)", attributes)
                    methods = self.methods.setdefault((name, "class" in attributes), set())
                    methods.add(getter.group(1) if getter else prop)
                    if "readonly" not in attributes:
                        methods.add("set" + prop[0].upper() + prop[1:] + ":")
        compat_file = tree / "translation/AppKit/PocketCompat.m"
        if compat_file.is_file():   # absent in the pinned platform alone (boot.py --pinned-appkit)
            compat = compat_file.read_text()
            for (name, class_side), selectors in ADDED_AT_LOAD.items():
                for selector in selectors:
                    if selector not in compat:
                        raise SystemExit(f"PocketCompat.m no longer adds {selector}; update tests/emulate/appkit.py")
                self.methods.setdefault((name, class_side), set()).update(selectors)
            defined |= {name for name, _ in ADDED_AT_LOAD}
        # Imported but not written: the platform's stub classes, NSObject underneath.
        self.classes = defined | set(imported)

    def __contains__(self, name: str) -> bool:
        return name in self.classes

    def implements(self, name: str, selector: str, class_side: bool) -> bool:
        if selector in NSOBJECT:
            return True
        seen = set()
        while name and name not in seen:
            seen.add(name)
            if selector in self.methods.get((name, class_side), set()):
                return True
            name = self.superclass.get(name)
        return False
