#!/usr/bin/env python3
"""Extract compatibility facts from the locally installed MFC 1.5.21 binary.

No vendor executable, XML resource or decompiled implementation is emitted.
Offsets are tied to the verified whole-file SHA-256; other builds are rejected.
This reads files only. It never launches MFC or accesses AppleSMC.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET
import zlib


BINARY_SHA256 = "65146b1964ae6f5a37f87c00ea9bd3b1d9a51265f72f022fbb0c3458487da8b3"
RESOURCES = [
    ("smcSensors-legacy", 2453374, 1723, 9901, "d01067ab9dfa74f0256a16c197f65a91ead94e961f6420dd218bad8ea5aaf642"),
    ("iokitSensors", 2455101, 551, 2689, "42e53da43fef70e217818cc5a6c380e938eef1a48213ad79ad5eef5f4b8cd9bf"),
    ("fanInfo", 2455656, 325, 1142, "f5af6b9e0b1e5034ec8bdc6a00db3f4652cb3ded690166ac2f501270f2e88ac4"),
    ("smcSensors-arm", 2456228, 1757, 17477, "b46187561e556b8e749fee230cc01956050de9ff352d30a7aac55c37b5986108"),
    ("idSwapRules", 2457989, 403, 2192, "8c7ab1f593e8f112485aa397b8656d5895b9ec07ea0b3e22965b49fef18c4fe5"),
]
ARM_RESOURCE_OFFSETS = [6194934, 6196661, 6197216, 6197779, 6199540]


def extract(binary):
    if hashlib.sha256(binary).hexdigest() != BINARY_SHA256:
        raise ValueError("Different MFC build: re-establish resource offsets before extraction.")
    catalog = {
        "schema": "aervane.compatibility.mfc/v1",
        "source": {"application": "Macs Fan Control", "version": "1.5.21", "build": "82",
                   "binary_sha256": BINARY_SHA256, "resource_architectures": ["x86_64", "arm64"],
                   "scope": "All five embedded sensor/fan/model resources; independently verified identical in both architecture slices. Separate control-key analysis."},
        "resources": [], "sensor_rules": [], "fan_rules": [], "id_swaps": [],
    }
    flat = []
    for (name, offset, size, expanded, digest), arm_offset in zip(RESOURCES, ARM_RESOURCE_OFFSETS):
        data = zlib.decompress(binary[offset:offset + size], 31)
        if len(data) != expanded or hashlib.sha256(data).hexdigest() != digest:
            raise ValueError(f"Resource verification failed: {name}")
        arm_data = zlib.decompress(binary[arm_offset:arm_offset + size], 31)
        if arm_data != data:
            raise ValueError(f"Architecture resource mismatch: {name}")
        root = ET.fromstring(data)
        catalog["resources"].append({"name": name, "offsets": {"x86_64": offset, "arm64": arm_offset}, "compressed_bytes": size,
                                     "expanded_bytes": expanded, "sha256": digest})
        if name == "idSwapRules":
            catalog["id_swaps"] = [dict(e.attrib) for e in root]
            continue
        for model in root:
            selector = model.attrib["models"]
            for entry in model:
                if name == "fanInfo":
                    catalog["fan_rules"].append({"models": selector, "fan": entry.tag,
                                                  "label": (entry.text or "").strip(), "attrs": dict(entry.attrib)})
                    continue
                rule = {"resource": name, "models": selector, "kind": entry.tag,
                        "attrs": dict(entry.attrib), "members": []}
                if entry.tag == "group":
                    rule["name"] = entry.attrib["name"]
                    for member in entry:
                        rule["members"].append({"key": member.attrib["name"],
                                                "label": (member.text or "").strip(),
                                                "type": member.attrib.get("type", ""), "attrs": dict(member.attrib)})
                        flat.append({"resource": name, "models": selector, "kind": member.tag,
                                     "group": rule["name"], "key": member.attrib["name"],
                                     "label": (member.text or "").strip(), "attrs": dict(member.attrib)})
                else:
                    rule.update(key=entry.attrib["name"], label=(entry.text or "").strip())
                    flat.append({"resource": name, "models": selector, "kind": entry.tag,
                                 "group": "", "key": rule["key"], "label": rule["label"], "attrs": dict(entry.attrib)})
                catalog["sensor_rules"].append(rule)
    keys = sorted({row["key"] for row in flat if row["kind"] == "smc"})
    if not all(len(key.encode("ascii")) == 4 for key in keys):
        raise ValueError("Unexpected SMC key width")
    catalog["counts"] = {"sensor_rules": len(catalog["sensor_rules"]), "sensor_rows": len(flat),
                         "smc_rows": sum(row["kind"] == "smc" for row in flat),
                         "unique_smc_sensor_keys": len(keys),
                         "iokit_rows": sum(row["kind"] == "iokit" for row in flat),
                         "fan_rules": len(catalog["fan_rules"]), "model_aliases": len(catalog["id_swaps"])}
    return catalog, flat, keys


def write_csv(path, fields, rows):
    with path.open("w", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow({key: json.dumps(value, ensure_ascii=False, sort_keys=True) if isinstance(value, dict) else value
                             for key, value in row.items()})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("output", type=Path, help="Directory for compatibility facts")
    args = parser.parse_args()
    catalog, flat, keys = extract(args.binary.read_bytes())
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "sensor-catalog.json").write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n")
    write_csv(args.output / "sensors-by-model.csv", ["resource", "models", "kind", "group", "key", "label", "attrs"], flat)
    write_csv(args.output / "model-aliases.csv", ["from", "to"], catalog["id_swaps"])
    write_csv(args.output / "fans-by-model.csv", ["models", "fan", "label", "attrs"], catalog["fan_rules"])
    (args.output / "smc-temperature-keys.txt").write_text("\n".join(keys) + "\n")
    print(json.dumps(catalog["counts"], sort_keys=True))


if __name__ == "__main__":
    main()
