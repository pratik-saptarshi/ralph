#!/usr/bin/env python3
"""JSONL span-record writer for Ralph telemetry (lib/ralph-telemetry.sh).

Appends ONE JSON object per finished span to the file named by
--file (or the RALPH_OTEL_FILE env var). The record shape is the
shared AEP telemetry contract, field-for-field identical to the
``_JsonlExporter._record`` output in AEP's tools/ghg/telemetry.py:

    name, trace_id, span_id, parent_span_id, start_time, end_time,
    status, attributes

Attributes arrive via repeated ``--attr key=value`` arguments and are
written verbatim: they have ALREADY passed through the single
attribute filter (``ralph_telemetry_set`` in ralph-telemetry.sh),
exactly as ghg's exporter deliberately does not re-filter what its
handle's set_attribute path produced. The only shaping done here is
typing: exit_code is emitted as an int and duration_ms as a float,
matching the contract's value types.

This writer never raises and always exits 0: telemetry must never
break the loop that emits it.
"""

import json
import os
import sys


def _parse_args(argv):
    opts = {"attr": []}
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--attr" and i + 1 < len(argv):
            opts["attr"].append(argv[i + 1])
            i += 2
        elif arg.startswith("--") and i + 1 < len(argv):
            opts[arg[2:].replace("-", "_")] = argv[i + 1]
            i += 2
        else:
            i += 1
    return opts


def _int_or(value, default):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _typed_attributes(pairs):
    attrs = {}
    for pair in pairs:
        if "=" not in pair:
            continue
        key, value = pair.split("=", 1)
        if key == "exit_code":
            attrs[key] = _int_or(value, 0)
        elif key == "duration_ms":
            try:
                attrs[key] = float(value)
            except (TypeError, ValueError):
                attrs[key] = 0.0
        else:
            attrs[key] = value
    return attrs


def main(argv):
    try:
        opts = _parse_args(argv)
        path = opts.get("file") or os.environ.get("RALPH_OTEL_FILE")
        if not path:
            return 0
        parent = opts.get("parent_span_id") or None
        record = {
            "name": opts.get("name", ""),
            "trace_id": opts.get("trace_id", "0" * 32),
            "span_id": opts.get("span_id", "0" * 16),
            "parent_span_id": parent,
            "start_time": _int_or(opts.get("start_ns"), 0),
            "end_time": _int_or(opts.get("end_ns"), 0),
            "status": opts.get("status", "UNSET"),
            "attributes": _typed_attributes(opts["attr"]),
        }
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(record) + "\n")
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
