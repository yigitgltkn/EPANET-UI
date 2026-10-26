"""Send values edited in QGIS back to the model that is open in EPANET-UI.

In the layers that qgis_load_results.py made, edit

    Nodes (pressure):  elevation, base_demand                    (junctions)
    Pipes (velocity):  diameter, length, roughness, status       (pipes;
                       status is Open, Closed or CV)

then click "Update EPANET" on the EPANET toolbar, or run inside QGIS:

    CONFIG = {"confirm": False}          # optional overrides
    exec(compile(open(path, encoding="utf-8").read(), path, "exec"), {"CONFIG": CONFIG})

The layers are compared with the files they were loaded from, so only what
was changed in QGIS is sent. EPANET-UI (started with --remote) checks every
value; if it refuses one, nothing is changed. The model is then run again and
the layers are refreshed with the new results.

Moving, adding or deleting features is not sent: for that, rebuild the model
from the GIS layers with qgis_to_inp.py. Such edits are reported as ignored.
"""
import inspect
import json
import os
import socket

from qgis.core import QgsProject
from qgis.PyQt.QtCore import Qt, QVariant
from qgis.PyQt.QtWidgets import QApplication, QMessageBox
from qgis.utils import iface

DEFAULTS = {
    "host": "127.0.0.1",
    "port": 9877,
    "confirm": True,          # show what will change and ask first; also shows errors in dialogs
    "run": True,              # run the model again and refresh the layers
    "timeout": 600,           # seconds to wait for EPANET-UI
    "max_listed": 15,         # changes listed in the confirmation
    "activate_epanet": True,  # bring EPANET-UI to the front when it has the new results
}
EDITABLE = {"nodes": ("elevation", "base_demand"),
            "links": ("diameter", "length", "roughness", "status")}
TITLE = "Update EPANET"

cfg = dict(DEFAULTS)
cfg.update(globals().get("CONFIG") or {})
here = os.path.dirname(os.path.abspath(inspect.currentframe().f_code.co_filename))


class UpdateError(Exception):
    pass


def _call(command, params=None):
    try:
        sock = socket.create_connection((cfg["host"], cfg["port"]), timeout=cfg["timeout"])
    except OSError:
        raise UpdateError("EPANET-UI does not answer on port %d. Start it with --remote "
                          "and open the model." % cfg["port"])
    with sock:
        sock.sendall(json.dumps({"type": command, "params": params or {}}).encode("utf-8"))
        data = b""
        while not data.endswith(b"\n"):
            chunk = sock.recv(65536)
            if not chunk:
                break
            data += chunk
    reply = json.loads(data.decode("utf-8"))
    if reply.get("status") != "success":
        raise UpdateError("EPANET-UI: %s" % reply.get("message"))
    return reply["result"]


def _value(v):
    return None if v is None or (isinstance(v, QVariant) and v.isNull()) else v


def _same(a, b):
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return abs(a - b) <= 1e-9 * max(1.0, abs(a))
    return a == b


def _coords(geometry):
    if geometry["type"] == "Point":
        return [geometry["coordinates"]]
    return geometry["coordinates"]


def _moved(feature, geometry):
    now = [(v.x(), v.y()) for v in feature.geometry().vertices()]
    before = _coords(geometry)
    return len(now) != len(before) or any(
        abs(x - b[0]) > 1e-6 or abs(y - b[1]) > 1e-6 for (x, y), b in zip(now, before))


def _layers():
    found = {}
    for layer in QgsProject.instance().mapLayers().values():
        role = layer.customProperty("epanet/role")
        if role in EDITABLE:
            found[role] = layer
    if len(found) < len(EDITABLE):
        raise UpdateError("No EPANET results layers in this project. "
                          "Load them with qgis_load_results.py first.")
    return found


def _diff(layer, role):
    """Values changed in the layer since it was loaded, and edits that cannot be sent."""
    path = layer.customProperty("epanet/file")
    if not path or not os.path.isfile(path):
        raise UpdateError("The file layer '%s' was loaded from is gone: %s" % (layer.name(), path))
    if repr(os.path.getmtime(path)) != layer.customProperty("epanet/mtime"):
        raise UpdateError("%s was written again after layer '%s' was loaded, so the edits "
                          "cannot be compared with it. Reload the results first."
                          % (os.path.basename(path), layer.name()))
    with open(path, encoding="utf-8") as f:
        base = {ft["properties"]["id"]: ft for ft in json.load(f)["features"]}

    names = [f.name() for f in layer.fields()]
    edits, ignored, seen = [], {}, set()
    for feature in layer.getFeatures():       # includes edits not saved yet
        fid = _value(feature["id"])
        if fid not in base:
            ignored["added features"] = ignored.get("added features", 0) + 1
            continue
        seen.add(fid)
        old = base[fid]["properties"]
        item = {}
        for name in names:
            if name not in old or _same(_value(feature[name]), old[name]):
                continue
            if name in EDITABLE[role]:
                item[name] = _value(feature[name])
            else:
                ignored[name] = ignored.get(name, 0) + 1
        if item:
            item["id"] = fid
            edits.append(item)
        if _moved(feature, base[fid]["geometry"]):
            ignored["moved features"] = ignored.get("moved features", 0) + 1
    deleted = len(set(base) - seen)
    if deleted:
        ignored["deleted features"] = deleted
    return edits, ignored, base, path


def _bring_epanet_forward():
    try:
        import ctypes
        ctypes.windll.user32.AllowSetForegroundWindow(-1)      # ASFW_ANY
    except (AttributeError, OSError):
        pass                                                    # not Windows
    try:
        _call("activate")
    except UpdateError:
        pass                                                    # older EPANET-UI


def _pressures(rows):
    values = [r["pressure"] for r in rows
              if r.get("type") == "Junction" and isinstance(r.get("pressure"), (int, float))]
    return (min(values), sum(values) / len(values), max(values)) if values else None


def _text(v):
    return "%g" % v if isinstance(v, (int, float)) else str(v)


def _change_text(c):
    kind = "junction" if c["category"] == "node" else "pipe"
    return "%s %s  %s: %s \u2192 %s" % (kind, c["id"], c["field"].replace("_", " "),
                                       _text(c["old"]), _text(c["new"]))


def _ignored_text(ignored):
    return ", ".join("%s (%d)" % (k.replace("_", " "), n) for k, n in sorted(ignored.items()))


def update():
    layers = _layers()
    node_edits, node_ignored, node_base, nodes_file = _diff(layers["nodes"], "nodes")
    link_edits, link_ignored, _, links_file = _diff(layers["links"], "links")
    ignored = dict(node_ignored)
    for k, n in link_ignored.items():
        ignored[k] = ignored.get(k, 0) + n
    summary = {"ignored": ignored}

    info = _call("get_project_info")
    model = os.path.splitext(os.path.basename(info.get("file") or ""))[0]
    source = os.path.basename(nodes_file)[:-len("_nodes.geojson")]
    if model.lower() != source.lower():
        raise UpdateError("EPANET-UI has %s open, but these layers come from %s.inp. "
                          "Open that model in EPANET-UI first."
                          % (os.path.basename(info.get("file") or "no model"), source))

    if not node_edits and not link_edits:
        summary.update(status="nothing_to_send", change_count=0)
        message = "No edited values to send."
        if ignored:
            message += " Ignored: " + _ignored_text(ignored) + "."
        return summary, message

    params = {"nodes": node_edits, "links": link_edits}
    check = _call("apply_edits", dict(params, dry_run=True))
    if check.get("problems"):
        lines = ["%s%s: %s" % (p.get("id", ""), " " + p["field"] if p.get("field") else "",
                               p["problem"]) for p in check["problems"]]
        raise UpdateError("EPANET-UI refused these values, so nothing was changed:\n\n"
                          + "\n".join(lines[:cfg["max_listed"]])
                          + ("\n..." if len(lines) > cfg["max_listed"] else ""))
    changes = check["changes"]
    if not changes:
        summary.update(status="nothing_to_send", change_count=0)
        return summary, "The model already has these values."

    if cfg["confirm"]:
        text = "%d change%s will be made in %s:\n\n" % (
            check["change_count"], "" if check["change_count"] == 1 else "s", os.path.basename(info["file"]))
        text += "\n".join(_change_text(c) for c in changes[:cfg["max_listed"]])
        if check["change_count"] > cfg["max_listed"]:
            text += "\n... and %d more" % (check["change_count"] - cfg["max_listed"])
        if ignored:
            text += "\n\nNot sent (only values can be updated): " + _ignored_text(ignored)
        if cfg["run"]:
            text += "\n\nThe model will then be run again and these layers refreshed."
        QApplication.restoreOverrideCursor()
        answer = QMessageBox.question(iface.mainWindow(), TITLE, text,
                                      QMessageBox.Ok | QMessageBox.Cancel, QMessageBox.Ok)
        QApplication.setOverrideCursor(Qt.WaitCursor)
        if answer != QMessageBox.Ok:
            summary.update(status="cancelled", change_count=check["change_count"])
            return summary, None

    applied = _call("apply_edits", params)
    if not applied.get("applied"):
        raise UpdateError("EPANET-UI did not apply the changes: %s" % applied.get("problems"))
    for layer in layers.values():
        if layer.isEditable() and not layer.commitChanges():
            raise UpdateError("The model was updated, but the edits in layer '%s' could not be "
                              "saved: %s" % (layer.name(), "; ".join(layer.commitErrors())))
    summary.update(status="updated", change_count=applied["change_count"], changes=applied["changes"])
    message = "%d value%s updated in %s." % (applied["change_count"],
                                              "" if applied["change_count"] == 1 else "s",
                                              os.path.basename(info["file"]))
    if not cfg["run"]:
        return summary, message

    run = _call("run_analysis")
    summary["run_status"] = run["status"]
    if run["status"] not in ("success", "warning"):
        raise UpdateError("The model was updated, but the run failed (%s):\n\n%s"
                          % (run["status"], run.get("status_report", "")[:1500]))
    export = _call("export_geojson", {"folder": os.path.dirname(nodes_file)})
    loader = os.path.join(here, "qgis_load_results.py")
    space = {"CONFIG": {"nodes_file": export["nodes_file"], "links_file": export["links_file"],
                        "zoom": False, "add_basemap": False}}
    exec(compile(open(loader, encoding="utf-8").read(), loader, "exec"), space)

    before = _pressures([ft["properties"] for ft in node_base.values()])
    after = _pressures([{"type": f["type"], "pressure": _value(f["pressure"])}
                        for f in layers["nodes"].getFeatures()])
    if before and after:
        units = info.get("pressure_units", "")
        summary["junction_pressure"] = {"units": units,
                                        "before_min_mean_max": [round(v, 2) for v in before],
                                        "after_min_mean_max": [round(v, 2) for v in after]}
        message += " Model run again: junction pressure min %.1f \u2192 %.1f %s, mean %.1f \u2192 %.1f %s." % (
            before[0], after[0], units, before[1], after[1], units)
    if run["status"] == "warning":
        message += " The run gave warnings; see the status report in EPANET-UI."
    if cfg["activate_epanet"]:
        _bring_epanet_forward()
    return summary, message


QApplication.setOverrideCursor(Qt.WaitCursor)
try:
    result, note = update()
except Exception as err:            # shown to the user, not left in the Python console
    QApplication.restoreOverrideCursor()
    if not isinstance(err, UpdateError):
        err = UpdateError("Unexpected error: %s: %s" % (type(err).__name__, err))
    result, note = {"status": "error", "message": str(err)}, None
    if cfg["confirm"]:
        QMessageBox.warning(iface.mainWindow(), TITLE, str(err))
    else:
        iface.messageBar().pushWarning(TITLE, str(err).split("\n")[0])
finally:
    QApplication.restoreOverrideCursor()
if note:
    iface.messageBar().pushSuccess(TITLE, note)
print(json.dumps(result, ensure_ascii=False))
