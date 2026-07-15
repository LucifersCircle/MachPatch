#!/usr/bin/env python3

import argparse
import json
import sys


def load_lief():
    try:
        import lief
    except Exception as error:
        return None, f"LIEF could not be imported: {error}"

    if not hasattr(lief, "objc"):
        return None, "the installed LIEF build does not include Extended Objective-C support"
    return lief, None


def method_dict(method):
    return {
        "name": method.name,
        "isInstance": bool(method.is_instance),
        "typeEncoding": method.mangled_type or None,
        "address": int(method.address) or None,
    }


def property_dict(prop):
    return {
        "name": prop.name,
        "attributes": prop.attribute or "",
    }


def ivar_dict(ivar):
    return {
        "name": ivar.name,
        "typeEncoding": ivar.mangled_type or "",
    }


def protocol_name(protocol):
    return protocol.mangled_name


def class_dict(clazz):
    superclass = clazz.super_class
    return {
        "name": clazz.name,
        "superclassName": superclass.name if superclass is not None else None,
        "methods": [method_dict(item) for item in clazz.methods if item is not None],
        "properties": [property_dict(item) for item in clazz.properties if item is not None],
        "ivars": [ivar_dict(item) for item in clazz.ivars if item is not None],
        "protocols": [protocol_name(item) for item in clazz.protocols if item is not None],
    }


def protocol_dict(protocol):
    required = [
        {"method": method_dict(item), "isRequired": True}
        for item in protocol.required_methods
        if item is not None
    ]
    optional = [
        {"method": method_dict(item), "isRequired": False}
        for item in protocol.optional_methods
        if item is not None
    ]
    return {
        "name": protocol.mangled_name,
        "methods": required + optional,
        "properties": [property_dict(item) for item in protocol.properties if item is not None],
        "adoptedProtocols": [],
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("path", nargs="?")
    parser.add_argument("--slice-index", type=int, default=0)
    parser.add_argument("--probe", action="store_true")
    arguments = parser.parse_args()

    lief, reason = load_lief()
    if arguments.probe:
        print(json.dumps({"available": lief is not None, "reason": reason}))
        return 0
    if lief is None:
        print(reason, file=sys.stderr)
        return 2
    if arguments.path is None:
        print("a Mach-O path is required", file=sys.stderr)
        return 2

    fat_binary = lief.MachO.parse(arguments.path)
    if fat_binary is None:
        print("LIEF could not parse the Mach-O input", file=sys.stderr)
        return 3
    binary = fat_binary.at(arguments.slice_index)
    if binary is None:
        print(f"slice index {arguments.slice_index} does not exist", file=sys.stderr)
        return 3

    metadata = binary.objc_metadata
    if metadata is None:
        result = {"classes": [], "protocols": [], "categories": []}
    else:
        result = {
            "classes": [class_dict(item) for item in metadata.classes if item is not None],
            "protocols": [protocol_dict(item) for item in metadata.protocols if item is not None],
            "categories": [],
        }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"LIEF Objective-C extraction failed: {error}", file=sys.stderr)
        raise SystemExit(4)
