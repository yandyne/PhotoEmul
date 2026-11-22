"""Write Adobe Camera Raw / Lightroom "Look" (creative) profiles.

A Look profile is an XMP file holding a crs:RGBTable that Lightroom
Classic, Lightroom (cloud) and Adobe Camera Raw apply on top of the base
camera profile. The table is applied to display-referred RGB.
"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass
from pathlib import Path
from xml.sax.saxutils import quoteattr, escape

from .rgbtable import RGBTable, encode_text, fingerprint, to_stream


@dataclass
class LookProfile:
    name: str
    table: RGBTable
    group: str = "spektrafilm"
    cluster: str = ""
    description: str = ""
    copyright: str = ""
    contact: str = ""

    @property
    def uuid(self) -> str:
        # Stable per-name UUID so re-baking replaces rather than duplicates.
        return hashlib.md5(f"spektrafilm4lr:{self.group}:{self.name}".encode()).hexdigest().upper()


def _alt(tag: str, value: str) -> str:
    return (
        f"   <crs:{tag}>\n"
        f"    <rdf:Alt>\n"
        f"     <rdf:li xml:lang=\"x-default\">{escape(value)}</rdf:li>\n"
        f"    </rdf:Alt>\n"
        f"   </crs:{tag}>\n"
    )


def render_xmp(profile: LookProfile) -> str:
    stream = to_stream(profile.table)
    fp = fingerprint(stream)
    text = encode_text(stream)
    attrs = [
        ('crs:PresetType', "Look"),
        ('crs:Cluster', profile.cluster),
        ('crs:UUID', profile.uuid),
        ('crs:SupportsAmount', "True"),
        ('crs:SupportsColor', "True"),
        ('crs:SupportsMonochrome', "True"),
        ('crs:SupportsHighDynamicRange', "True"),
        ('crs:SupportsNormalDynamicRange', "True"),
        ('crs:SupportsSceneReferred', "True"),
        ('crs:SupportsOutputReferred', "True"),
        ('crs:RequiresRGBTables', "False"),
        ('crs:CameraModelRestriction', ""),
        ('crs:Copyright', profile.copyright),
        ('crs:ContactInfo', profile.contact),
        ('crs:Version', "16.5"),
        ('crs:ProcessVersion', "15.4"),
        ('crs:ConvertToGrayscale', "False"),
        ('crs:RGBTable', fp),
        (f'crs:Table_{fp}', text),
        ('crs:HasSettings', "True"),
    ]
    attr_text = "\n".join(f"   {k}={quoteattr(v)}" for k, v in attrs)
    return (
        '<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0-c000 1.000000, 0000/00/00-00:00:00        ">\n'
        ' <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n'
        '  <rdf:Description rdf:about=""\n'
        '    xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"\n'
        f"{attr_text}>\n"
        + _alt("Name", profile.name)
        + _alt("ShortName", profile.name)
        + _alt("SortName", profile.name)
        + _alt("Group", profile.group)
        + _alt("Description", profile.description)
        + "  </rdf:Description>\n"
        " </rdf:RDF>\n"
        "</x:xmpmeta>\n"
    )


def write_xmp(profile: LookProfile, path: Path) -> Path:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(render_xmp(profile), encoding="utf-8")
    return path
