#!/usr/bin/env python3
"""Upsert a Sparkle appcast item for a released DMG."""

from __future__ import annotations

import argparse
import datetime as dt
import email.utils
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SPARKLE = f"{{{SPARKLE_NS}}}"

ET.register_namespace("sparkle", SPARKLE_NS)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Add or replace one release item in a Sparkle appcast."
    )
    parser.add_argument("--appcast", required=True, type=Path)
    parser.add_argument("--version", required=True, help="CFBundleVersion / sparkle:version")
    parser.add_argument("--short-version", required=True, help="CFBundleShortVersionString")
    parser.add_argument("--download-url", required=True)
    parser.add_argument("--ed-signature", required=True)
    parser.add_argument("--length", required=True, type=int)
    parser.add_argument("--minimum-system-version", default="14.0.0")
    parser.add_argument("--title")
    parser.add_argument("--mime-type", default="application/octet-stream")
    parser.add_argument("--pub-date")
    return parser.parse_args()


def require_non_empty(name: str, value: str) -> None:
    if not value.strip():
        raise ValueError(f"{name} must not be empty")


def sparkle_text(parent: ET.Element, name: str, value: str) -> None:
    ET.SubElement(parent, f"{SPARKLE}{name}").text = value


def build_item(args: argparse.Namespace) -> ET.Element:
    pub_date = args.pub_date
    if not pub_date:
        pub_date = email.utils.format_datetime(
            dt.datetime.now(dt.timezone.utc),
            usegmt=True,
        )

    item = ET.Element("item")
    ET.SubElement(item, "title").text = args.title or f"Version {args.short_version}"
    ET.SubElement(item, "pubDate").text = pub_date
    sparkle_text(item, "version", args.version)
    sparkle_text(item, "shortVersionString", args.short_version)
    sparkle_text(item, "minimumSystemVersion", args.minimum_system_version)
    ET.SubElement(
        item,
        "enclosure",
        {
            "url": args.download_url,
            f"{SPARKLE}edSignature": args.ed_signature,
            "length": str(args.length),
            "type": args.mime_type,
        },
    )
    return item


def item_matches(item: ET.Element, version: str, short_version: str) -> bool:
    return (
        item.findtext(f"{SPARKLE}version") == version
        or item.findtext(f"{SPARKLE}shortVersionString") == short_version
    )


def upsert_item(channel: ET.Element, new_item: ET.Element, args: argparse.Namespace) -> str:
    existing_items = [
        item
        for item in list(channel)
        if item.tag == "item" and item_matches(item, args.version, args.short_version)
    ]
    for item in existing_items:
        channel.remove(item)

    children = list(channel)
    first_item_index = next(
        (index for index, child in enumerate(children) if child.tag == "item"),
        len(children),
    )
    channel.insert(first_item_index, new_item)

    return "updated" if existing_items else "added"


def main() -> int:
    args = parse_args()
    try:
        require_non_empty("version", args.version)
        require_non_empty("short-version", args.short_version)
        require_non_empty("download-url", args.download_url)
        require_non_empty("ed-signature", args.ed_signature)

        tree = ET.parse(args.appcast)
        root = tree.getroot()
        channel = root.find("channel")
        if channel is None:
            raise ValueError(f"{args.appcast} does not contain an RSS channel")

        result = upsert_item(channel, build_item(args), args)
        ET.indent(tree, space="  ")
        tree.write(args.appcast, encoding="utf-8", xml_declaration=True)
        print(f"{result} appcast item for {args.short_version} ({args.version})")
        return 0
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
