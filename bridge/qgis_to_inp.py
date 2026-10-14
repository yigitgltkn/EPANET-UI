"""Build an EPANET input file from pipe, node and tank layers open in QGIS.

Run inside QGIS (for example through the QGIS MCP plugin):

    CONFIG = {"out_file": r"D:\\some\\folder\\model.inp"}   # optional overrides
    exec(open(r"...\\bridge\\qgis_to_inp.py", encoding="utf-8").read())

The layers hold geometry and pipe sizes but no hydraulic model, so several
values are assumed. They are listed in DEFAULTS and repeated in the summary
that is printed at the end and written to the [TITLE] of the file.
"""
import json
import math
import os
from collections import defaultdict

from qgis.core import QgsProject

DEFAULTS = {
    "pipes_layer": "borular",
    "nodes_layer": "noktalar",
    "tank_layer": "depo",
    "out_file": None,             # None = model.inp beside the QGIS project
    "epsg": None,                 # None = take it from the pipes layer
    "snap_tol": 0.01,             # m, pipe end to node / pipe end to pipe end
    "tank_search": 1.0,           # m, how close the network must come to the tank
    # Assumed values, not in the GIS data:
    "hw_c": 140,                  # Hazen-Williams C used for every pipe
    "diameter_is_inner": True,    # diameter field is used as-is
    "service_max_diam": 40,       # mm; dead ends of pipes this size are customers
    "demand_per_service": 0.01,   # L/s at each customer connection
    "tank_depth": 4.0,            # m of water when full (diameter from volume)
    "tank_init": 3.0,             # m
    "tank_min": 0.5,              # m
}
cfg = dict(DEFAULTS)
cfg.update(globals().get("CONFIG") or {})


def _num(value):
    try:
        v = float(value)
    except (TypeError, ValueError):
        return None
    return v if v == v else None


def _layer(name):
    found = QgsProject.instance().mapLayersByName(name)
    if not found:
        raise RuntimeError("layer not found: %s" % name)
    return found[0]


pipes_lyr = _layer(cfg["pipes_layer"])
nodes_lyr = _layer(cfg["nodes_layer"])
tank_lyr = _layer(cfg["tank_layer"])
tol = cfg["snap_tol"]

# --- nodes -----------------------------------------------------------------
node_xy = {}
node_elev_raw = {}
for f in nodes_lyr.getFeatures():
    g = f.geometry()
    if g.isEmpty():
        continue
    p = g.constGet()
    nid = f["id"]
    node_xy[nid] = (p.x(), p.y())
    node_elev_raw[nid] = [_num(f["terrain_el"]), _num(f["oda_base_e"]), p.z()]

node_grid = defaultdict(list)
for nid, (x, y) in node_xy.items():
    node_grid[(round(x / tol), round(y / tol))].append(nid)


def _nearest_node(x, y):
    best, best_d = None, None
    cx, cy = round(x / tol), round(y / tol)
    for i in (-1, 0, 1):
        for j in (-1, 0, 1):
            for nid in node_grid.get((cx + i, cy + j), ()):
                nx, ny = node_xy[nid]
                d = math.hypot(nx - x, ny - y)
                if d <= tol and (best_d is None or d < best_d):
                    best, best_d = nid, d
    return best


# --- pipes -----------------------------------------------------------------
# A vertex is a model node: ("n", node id) where a pipe end sits on a GIS
# node, otherwise ("e", grid x, grid y) for a free pipe end.
vertex_xy = {}
vertex_z = defaultdict(list)      # elevations seen at the vertex from pipes
pipes = []
skipped = {"empty_geometry": 0, "same_start_and_end": 0}
missing_diameter = 0
length_from_geometry = 0


def _vertex(pt, z, field_elev):
    nid = _nearest_node(pt.x(), pt.y())
    if nid is not None:
        key = ("n", nid)
        vertex_xy[key] = node_xy[nid]
    else:
        key = ("e", round(pt.x() / tol), round(pt.y() / tol))
        vertex_xy.setdefault(key, (pt.x(), pt.y()))
    vertex_z[key].extend([z, field_elev])
    return key


for f in pipes_lyr.getFeatures():
    g = f.geometry()
    if g.isEmpty():
        skipped["empty_geometry"] += 1
        continue
    geom = g.constGet()
    line = geom.geometryN(0) if g.isMultipart() else geom
    n = line.numPoints()
    a, b = line.pointN(0), line.pointN(n - 1)
    ka = _vertex(a, a.z(), _num(f["oda_from_e"]))
    kb = _vertex(b, b.z(), _num(f["oda_to_ele"]))
    if ka == kb:
        skipped["same_start_and_end"] += 1
        continue
    length = _num(f["length"])
    if not length or length <= 0:
        length = g.length()
        length_from_geometry += 1
    diameter = _num(f["diameter"])
    if not diameter or diameter <= 0:
        diameter = None
        missing_diameter += 1
    pipes.append({
        "id": f["id"], "a": ka, "b": kb, "length": max(length, 0.1),
        "diameter": diameter,
        "inner": [(line.pointN(i).x(), line.pointN(i).y()) for i in range(1, n - 1)],
    })

# --- tank ------------------------------------------------------------------
tank_f = next(tank_lyr.getFeatures())
tank_pt = tank_f.geometry().constGet()
tank_key, tank_d = None, None
for key, (x, y) in vertex_xy.items():
    d = math.hypot(x - tank_pt.x(), y - tank_pt.y())
    if d <= cfg["tank_search"] and (tank_d is None or d < tank_d):
        tank_key, tank_d = key, d
if tank_key is None:
    raise RuntimeError("no pipe ends within %.1f m of the tank" % cfg["tank_search"])

# --- keep the part of the network that the tank supplies ---------------------
parent = {}


def _find(k):
    parent.setdefault(k, k)
    while parent[k] != k:
        parent[k] = parent[parent[k]]
        k = parent[k]
    return k


for p in pipes:
    ra, rb = _find(p["a"]), _find(p["b"])
    if ra != rb:
        parent[ra] = rb
root = _find(tank_key)
kept = [p for p in pipes if _find(p["a"]) == root]
dropped_pipes = len(pipes) - len(kept)
pipes = kept

degree = defaultdict(int)
incident = defaultdict(list)
for p in pipes:
    for k in (p["a"], p["b"]):
        degree[k] += 1
        incident[k].append(p)
vertices = list(degree)

# --- elevations ------------------------------------------------------------
valid_terrain = sorted(v[0] for v in node_elev_raw.values() if v[0])
median = valid_terrain[len(valid_terrain) // 2]
lo, hi = 0.5 * median, 1.5 * median


def _ok(v):
    return v is not None and lo < v < hi


elev = {}
elev_source = defaultdict(int)
for k in vertices:
    candidates = []
    if k[0] == "n":
        candidates += [("node terrain_el", node_elev_raw[k[1]][0]),
                       ("node oda_base_e", node_elev_raw[k[1]][1]),
                       ("node geometry z", node_elev_raw[k[1]][2])]
    candidates += [("pipe end", z) for z in vertex_z[k]]
    for source, v in candidates:
        if _ok(v):
            elev[k] = v
            elev_source[source] += 1
            break

# Fill what is left from neighbouring vertices
pending = [k for k in vertices if k not in elev]
filled_from_neighbours = 0
while pending:
    progress = []
    for k in pending:
        near = [elev[o] for p in incident[k] for o in (p["a"], p["b"]) if o != k and o in elev]
        if near:
            progress.append((k, sum(near) / len(near)))
    if not progress:
        for k in pending:
            elev[k] = median
        break
    for k, v in progress:
        elev[k] = v
        filled_from_neighbours += 1
    pending = [k for k in pending if k not in elev]

tank_elev = _num(tank_f["terrain_el"])
if not _ok(tank_elev):
    tank_elev = elev[tank_key]

# --- ids, demands ------------------------------------------------------------
ids = {}
end_count = 0
for k in vertices:
    if k == tank_key:
        ids[k] = "DEPO"
    elif k[0] == "n":
        ids[k] = "N%s" % k[1]
    else:
        end_count += 1
        ids[k] = "E%d" % end_count

demand = {}
for k in vertices:
    if k == tank_key or degree[k] != 1:
        continue
    d = incident[k][0]["diameter"]
    if d is not None and d <= cfg["service_max_diam"]:
        demand[k] = cfg["demand_per_service"]
total_demand = sum(demand.values())

fallback_diam = 90.0
tank_volume = _num(tank_f["hacim"]) or 1000.0
tank_diam = math.sqrt(4.0 * tank_volume / (math.pi * cfg["tank_depth"]))
epsg = cfg["epsg"] or int(pipes_lyr.crs().authid().split(":")[-1])

# --- write the file ----------------------------------------------------------
xs = [vertex_xy[k][0] for k in vertices]
ys = [vertex_xy[k][1] for k in vertices]
assumptions = [
    "Hazen-Williams C = %g for all pipes" % cfg["hw_c"],
    "pipe diameter taken as given in the GIS data (mm)",
    "demand of %g L/s at each dead end of a pipe of %g mm or less (%d points, %.2f L/s in total)"
    % (cfg["demand_per_service"], cfg["service_max_diam"], len(demand), total_demand),
    "tank of %g m3 modelled %g m deep (diameter %.2f m), initial level %g m"
    % (tank_volume, cfg["tank_depth"], tank_diam, cfg["tank_init"]),
    "single-period (steady state) analysis",
]

L = []
L += ["[TITLE]", "Draft model built from GIS layers; demands are assumed, not measured.",
      "Assumed: " + "; ".join(assumptions[:2]) + ".",
      "Assumed: " + "; ".join(assumptions[2:4]) + ".", ""]
L += ["[JUNCTIONS]", ";ID\tElev\tDemand"]
for k in vertices:
    if k != tank_key:
        L.append("%s\t%.2f\t%g" % (ids[k], elev[k], demand.get(k, 0)))
L += ["", "[TANKS]", ";ID\tElev\tInitLvl\tMinLvl\tMaxLvl\tDiam\tMinVol",
      "DEPO\t%.2f\t%g\t%g\t%g\t%.2f\t0" % (tank_elev, cfg["tank_init"], cfg["tank_min"],
                                         cfg["tank_depth"], tank_diam), ""]
L += ["[PIPES]", ";ID\tNode1\tNode2\tLength\tDiam\tRough\tMLoss\tStatus"]
seen = defaultdict(int)
for p in pipes:
    seen[p["id"]] += 1
    p["name"] = "P%s" % p["id"] if seen[p["id"]] == 1 else "P%s_%d" % (p["id"], seen[p["id"]])
    L.append("%s\t%s\t%s\t%.2f\t%g\t%g\t0\tOpen" % (
        p["name"], ids[p["a"]], ids[p["b"]], p["length"],
        p["diameter"] or fallback_diam, cfg["hw_c"]))
L += ["", "[OPTIONS]", "Units\tLPS", "Headloss\tH-W", "",
      "[TIMES]", "Duration\t0", "",
      "[COORDINATES]", ";Node\tX\tY"]
for k in vertices:
    L.append("%s\t%.3f\t%.3f" % (ids[k], vertex_xy[k][0], vertex_xy[k][1]))
L += ["", "[VERTICES]", ";Link\tX\tY"]
for p in pipes:
    for x, y in p["inner"]:
        L.append("%s\t%.3f\t%.3f" % (p["name"], x, y))
pad_x, pad_y = 0.05 * (max(xs) - min(xs)), 0.05 * (max(ys) - min(ys))
L += ["", "[BACKDROP]",
      "DIMENSIONS\t%.3f\t%.3f\t%.3f\t%.3f" % (min(xs) - pad_x, min(ys) - pad_y,
                                             max(xs) + pad_x, max(ys) + pad_y),
      "UNITS\tmeters\t%d" % epsg, 'FILE\t""', "", "[END]", ""]

out_file = cfg["out_file"] or os.path.join(
    QgsProject.instance().homePath() or os.path.expanduser("~"), "model.inp")
os.makedirs(os.path.dirname(out_file), exist_ok=True)
with open(out_file, "w", encoding="ascii", errors="replace", newline="\r\n") as fh:
    fh.write("\n".join(L))

summary = {
    "file": out_file,
    "epsg": epsg,
    "junctions": len(vertices) - 1,
    "junctions_from_gis_nodes": sum(1 for k in vertices if k[0] == "n" and k != tank_key),
    "junctions_created_at_free_pipe_ends": end_count,
    "tanks": 1,
    "pipes": len(pipes),
    "pipe_length_km": round(sum(p["length"] for p in pipes) / 1000.0, 1),
    "not_included": {
        "pipes_not_connected_to_the_tank": dropped_pipes,
        "pipes_with_same_start_and_end": skipped["same_start_and_end"],
        "pipes_with_empty_geometry": skipped["empty_geometry"],
        "gis_nodes_not_at_any_pipe_end": len(node_xy) - sum(1 for k in vertex_xy if k[0] == "n"),
    },
    "data_repairs": {
        "pipe_lengths_taken_from_geometry": length_from_geometry,
        "pipes_given_fallback_diameter_%g" % fallback_diam: missing_diameter,
        "elevations_filled_from_neighbours": filled_from_neighbours,
        "elevation_sources": dict(elev_source),
    },
    "elevation_range_m": [round(min(elev.values()), 1), round(max(elev.values()), 1)],
    "tank_elevation_m": round(tank_elev, 2),
    "demand_points": len(demand),
    "total_demand_lps": round(total_demand, 2),
    "assumptions": assumptions,
}
print(json.dumps(summary, ensure_ascii=False, indent=1))
