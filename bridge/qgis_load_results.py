"""Show EPANET-UI results (written by its export_geojson command) in QGIS.

Run inside QGIS (for example through the QGIS MCP plugin):

    CONFIG = {"nodes_file": r"...\\model_nodes.geojson",
              "links_file": r"...\\model_links.geojson"}
    exec(compile(open(path, encoding="utf-8").read(), path, "exec"), {"CONFIG": CONFIG})

The features are copied into memory layers so that QGIS does not keep the
GeoJSON files open; EPANET-UI can then overwrite them after the next run.
Running the script again refreshes the same layers and keeps their styling.

It also puts an "Update EPANET" button on an EPANET toolbar: values edited
in these layers are sent back to EPANET-UI (see qgis_update_epanet.py).
"""
import inspect
import json
import os

from qgis.core import (QgsFeatureRequest, QgsGraduatedSymbolRenderer, QgsLayerTreeLayer,
                       QgsLineSymbol, QgsMarkerSymbol, QgsProject, QgsProperty,
                       QgsRasterLayer, QgsRendererRange, QgsStyle, QgsSymbolLayer,
                       QgsVectorLayer)
from qgis.PyQt.QtWidgets import QAction, QToolBar
from qgis.utils import iface

DEFAULTS = {
    "nodes_file": "",
    "links_file": "",
    "group": "EPANET results",
    "nodes_name": "Nodes (pressure)",
    "links_name": "Pipes (velocity)",
    "pressure_breaks": [20, 40, 60, 80],          # in the model's pressure units
    "velocity_breaks": [0.05, 0.2, 0.5],          # in the model's velocity units
    "hide_layers": [],                            # source layers to switch off
    "add_basemap": True,
    "zoom": True,
    "update_script": None,                        # None = qgis_update_epanet.py beside this file
}
cfg = dict(DEFAULTS)
cfg.update(globals().get("CONFIG") or {})

project = QgsProject.instance()
root = project.layerTreeRoot()
report = {}


def _read(path):
    """Copy a file's features into a memory layer and release the file."""
    source = QgsVectorLayer(path, "source", "ogr")
    if not source.isValid():
        raise RuntimeError("could not read %s" % path)
    copy = source.materialize(QgsFeatureRequest())
    del source
    return copy


def _labels(breaks):
    text = ["%g" % b for b in breaks]
    return (["< " + text[0]] + ["%s – %s" % (text[i], text[i + 1]) for i in range(len(text) - 1)]
            + ["> " + text[-1]])


def _graduated(layer, field, breaks, ramp_name, make_symbol, ramp_start=0.0):
    ramp = QgsStyle.defaultStyle().colorRamp(ramp_name)
    bounds = [-1e12] + list(breaks) + [1e12]
    labels = _labels(breaks)
    ranges = []
    for i, label in enumerate(labels):
        symbol = make_symbol()
        symbol.setColor(ramp.color(ramp_start + (1 - ramp_start) * i / (len(labels) - 1)))
        ranges.append(QgsRendererRange(bounds[i], bounds[i + 1], symbol, label))
    layer.setRenderer(QgsGraduatedSymbolRenderer(field, ranges))


def _line_symbol():
    symbol = QgsLineSymbol.createSimple({"width": "0.4", "capstyle": "round"})
    symbol.symbolLayer(0).setDataDefinedProperty(
        QgsSymbolLayer.PropertyStrokeWidth,
        QgsProperty.fromExpression('scale_linear("diameter", 32, 355, 0.3, 2.0)'))
    return symbol


def _marker_symbol():
    return QgsMarkerSymbol.createSimple({"name": "circle", "size": "1.1", "outline_style": "no"})


def _existing(role):
    """The layer this script made for "nodes" or "links" last time, wherever it is now."""
    for layer in project.mapLayers().values():
        if layer.customProperty("epanet/role") == role and layer.dataProvider().name() == "memory":
            return layer
    return None


def _show(path, role, name, style):
    fresh = _read(path)
    layer = _existing(role)
    if layer is not None and [f.name() for f in layer.fields()] == [f.name() for f in fresh.fields()]:
        # Same layer as last time: swap its contents, keep its styling
        provider = layer.dataProvider()
        provider.truncate()
        provider.addFeatures(list(fresh.getFeatures()))
        layer.updateExtents()
        layer.triggerRepaint()
        state = "refreshed"
    else:
        if layer is not None:          # made by an older export with other fields
            project.removeMapLayer(layer.id())
        layer = fresh
        layer.setName(name)
        style(layer)
        project.addMapLayer(layer, False)
        state = "created"
    # What qgis_update_epanet.py compares the edited values with
    layer.setCustomProperty("epanet/role", role)
    layer.setCustomProperty("epanet/file", path)
    layer.setCustomProperty("epanet/mtime", repr(os.path.getmtime(path)))
    return layer, state


def _group():
    found = root.findGroup(cfg["group"])
    return found if found is not None else root.insertGroup(0, cfg["group"])


def _add_update_button(script):
    """An "Update EPANET" button on an EPANET toolbar, made once per QGIS session."""
    window = iface.mainWindow()
    action = window.findChild(QAction, "epanetUpdateAction")
    if action is None:
        action = QAction("Update EPANET", window)
        action.setObjectName("epanetUpdateAction")
        action.setToolTip("Send the values edited in the EPANET results layers to EPANET-UI, "
                          "run the model again and refresh the layers")
    # Owned by the main window: iface.addToolBar("...") would leave it to Python,
    # which deletes it when this script ends
    toolbar = window.findChild(QToolBar, "epanetToolbar")
    if toolbar is None:
        toolbar = QToolBar("EPANET", window)
        toolbar.setObjectName("epanetToolbar")
        window.addToolBar(toolbar)
    if action not in toolbar.actions():
        toolbar.addAction(action)
    toolbar.setVisible(True)
    try:
        action.triggered.disconnect()
    except TypeError:
        pass
    action.triggered.connect(lambda: exec(
        compile(open(script, encoding="utf-8").read(), script, "exec"), {"CONFIG": {"confirm": True}}))


# Drop a result group made from files directly (it would keep the files locked)
group = root.findGroup(cfg["group"])
if group is not None and any(n.layer() is not None and n.layer().dataProvider().name() != "memory"
                             for n in group.findLayers()):
    for node in group.findLayers():
        project.removeMapLayer(node.layerId())
    root.removeChildNode(group)

nodes, report["nodes"] = _show(
    cfg["nodes_file"], "nodes", cfg["nodes_name"],
    lambda lyr: _graduated(lyr, "pressure", cfg["pressure_breaks"], "RdYlBu", _marker_symbol))
links, report["links"] = _show(
    cfg["links_file"], "links", cfg["links_name"],
    lambda lyr: _graduated(lyr, "velocity", cfg["velocity_breaks"], "Blues", _line_symbol, 0.45))
if report["nodes"] == "created":
    _group().insertLayer(0, nodes)
if report["links"] == "created":
    _group().addLayer(links)

update_script = cfg.get("update_script") or os.path.join(
    os.path.dirname(os.path.abspath(inspect.currentframe().f_code.co_filename)), "qgis_update_epanet.py")
report["update_button"] = os.path.isfile(update_script)
if report["update_button"]:
    _add_update_button(update_script)

for name in cfg["hide_layers"]:
    for layer in project.mapLayersByName(name):
        node = root.findLayer(layer.id())
        if node is not None:
            node.setItemVisibilityChecked(False)

if cfg["add_basemap"] and not any(isinstance(l, QgsRasterLayer) for l in project.mapLayers().values()):
    osm = QgsRasterLayer("type=xyz&url=https://tile.openstreetmap.org/{z}/{x}/{y}.png&zmax=19&zmin=0",
                         "OpenStreetMap", "wms")
    if osm.isValid():
        project.addMapLayer(osm, False)
        root.insertChildNode(-1, QgsLayerTreeLayer(osm))

canvas = iface.mapCanvas()
if cfg["zoom"] and "created" in (report["nodes"], report["links"]):
    extent = canvas.mapSettings().layerExtentToOutputExtent(links, links.extent())
    extent.scale(1.05)
    canvas.setExtent(extent)
canvas.refreshAllLayers()

pressures = [f["pressure"] for f in nodes.getFeatures()
             if f["type"] == "Junction" and f["pressure"] is not None]
report.update({
    "node_features": nodes.featureCount(),
    "link_features": links.featureCount(),
    "crs": nodes.crs().authid(),
    "junction_pressure_min_mean_max": [round(min(pressures), 2),
                                       round(sum(pressures) / len(pressures), 2),
                                       round(max(pressures), 2)] if pressures else None,
})
print(json.dumps(report, ensure_ascii=False))
