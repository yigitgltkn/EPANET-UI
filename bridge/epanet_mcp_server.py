# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp[cli]>=1.3.0,<2"]
# ///
"""MCP server that lets Claude drive EPANET-UI and pass its results to QGIS.

EPANET-UI must run with its command channel on (epanet-ui.exe --remote).
export_to_qgis returns code for the QGIS MCP plugin's execute_code tool.

Register it with Claude Code, for example in a project's .mcp.json:

    {"mcpServers": {"epanet": {"command": "uv",
        "args": ["run", "--script", "<path>\\epanet_mcp_server.py"]}}}
"""
import json
import os
import socket
from typing import Any, Optional

from mcp.server.fastmcp import FastMCP

EPANET_PORT = int(os.environ.get("EPANET_UI_PORT", "9877"))
BRIDGE = os.path.dirname(os.path.abspath(__file__))

mcp = FastMCP("epanet")


def _request(port: int, command: str, params: dict, timeout: float = 600) -> dict:
    with socket.create_connection(("127.0.0.1", port), timeout=timeout) as sock:
        sock.sendall(json.dumps({"type": command, "params": params}).encode("utf-8"))
        data = b""
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            data += chunk
            try:
                return json.loads(data.decode("utf-8"))
            except ValueError:
                continue
    return json.loads(data.decode("utf-8"))


def _epanet(command: str, **params: Any) -> str:
    """Send a command to EPANET-UI and return its result as JSON text."""
    params = {k: v for k, v in params.items() if v is not None}
    try:
        reply = _request(EPANET_PORT, command, params)
    except OSError:
        raise RuntimeError("EPANET-UI does not answer on port %d; start it with --remote" % EPANET_PORT)
    if reply.get("status") != "success":
        raise RuntimeError(reply.get("message", "EPANET-UI refused the command"))
    return json.dumps(reply["result"], ensure_ascii=False)


@mcp.tool()
def get_project_info() -> str:
    """Describe the network open in EPANET-UI: file, element counts, units,
    whether results exist, and the node/link themes that can be shown."""
    return _epanet("get_project_info")


@mcp.tool()
def open_project(path: str, discard_changes: bool = False) -> str:
    """Open an EPANET input (.inp) file in EPANET-UI."""
    return _epanet("open_project", path=path, discard_changes=discard_changes)


@mcp.tool()
def run_analysis() -> str:
    """Run the hydraulic simulation in EPANET-UI, as its Analyze button does."""
    return _epanet("run_analysis")


@mcp.tool()
def get_results(category: str, theme: str, period: Optional[int] = None,
                types: Optional[list[str]] = None, ids: Optional[list[str]] = None,
                below: Optional[float] = None, above: Optional[float] = None,
                sort: Optional[str] = None, limit: Optional[int] = None) -> str:
    """Values of one theme for nodes or links, in the project's units.

    category: "nodes" or "links"; theme: e.g. "Pressure", "Head", "Flow Rate",
    "Velocity", "Diameter". types filters element types, e.g. ["Junction"]
    (node results also include tanks and reservoirs). sort: "asc" or "desc".
    """
    return _epanet("get_results", category=category, theme=theme, period=period, types=types,
                   ids=ids, below=below, above=above, sort=sort, limit=limit)


@mcp.tool()
def set_map_view(node_theme: Optional[str] = None, link_theme: Optional[str] = None,
                 period: Optional[int] = None) -> str:
    """Choose what EPANET-UI's map colours nodes and links by, e.g.
    node_theme="Pressure", link_theme="Velocity"."""
    return _epanet("set_map_view", node_theme=node_theme, link_theme=link_theme, period=period)


@mcp.tool()
def apply_edits(nodes: Optional[list[dict]] = None, links: Optional[list[dict]] = None,
                dry_run: bool = False) -> str:
    """Change junction or pipe properties in the open model.

    nodes: [{"id": "J-1", "elevation": 250, "base_demand": 10}, ...]
    links: [{"id": "P-1", "diameter": 8, "length": 300, "roughness": 120,
             "status": "Open" | "Closed" | "CV"}, ...]
    Values are in the project's units. If any value is refused, nothing is
    changed. Run the analysis again afterwards to get new results.
    """
    return _epanet("apply_edits", nodes=nodes or [], links=links or [], dry_run=dry_run)


@mcp.tool()
def set_3d_view(show: bool = True, valve: Optional[str] = None, reset: Optional[bool] = None,
                yaw: Optional[float] = None, pitch: Optional[float] = None,
                zoom: Optional[float] = None, vertical_scale: Optional[float] = None,
                flow: Optional[bool] = None) -> str:
    """Show EPANET-UI's 3D view of the hydraulic grade line (show=False goes
    back to the map). valve: a valve ID for its close-up, "" for the network.
    The view is drawn from EPANET results; it is not a CFD simulation."""
    return _epanet("set_3d_view", show=show, valve=valve, reset=reset, yaw=yaw, pitch=pitch,
                   zoom=zoom, vertical_scale=vertical_scale, flow=flow)


@mcp.tool()
def export_to_qgis(zoom: bool = True) -> str:
    """Export the network and its latest results from EPANET-UI for QGIS.

    Returns "qgis_code": run it with the qgis execute_code tool to show the
    results in QGIS (nodes coloured by pressure, pipes by velocity, on a
    basemap; running it again refreshes the same layers). Engineers can then
    edit values in those layers and send them back with QGIS's "Update
    EPANET" button. (The QGIS MCP plugin serves one connection at a time, so
    this server does not talk to QGIS itself.)"""
    info = json.loads(_epanet("get_project_info"))
    files = json.loads(_epanet("export_geojson"))
    us = info.get("pressure_units") == "psi"
    config = {"nodes_file": files["nodes_file"], "links_file": files["links_file"], "zoom": zoom,
              "pressure_breaks": [40, 60, 80, 100] if us else [20, 40, 60, 80],
              "velocity_breaks": [0.25, 1, 2] if us else [0.05, 0.2, 0.5]}
    loader = os.path.join(BRIDGE, "qgis_load_results.py")
    code = ("path = %r\nexec(compile(open(path, encoding='utf-8').read(), path, 'exec'), {'CONFIG': %r})"
            % (loader, config))
    return json.dumps({"node_count": files["node_count"], "link_count": files["link_count"],
                       "qgis_code": code}, ensure_ascii=False)


if __name__ == "__main__":
    mcp.run()
