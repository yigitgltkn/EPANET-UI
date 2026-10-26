# EPANET Graphical User Interface
![](screenshot.png)

> **About this fork** (branch `yg-main`): it links EPANET-UI with QGIS in both directions and lets other
> programs drive it. The additions were written with Claude Code.
> - **QGIS button** (Project tab): sends the network and its latest results to QGIS through the
>   [QGIS MCP plugin](https://github.com/jjsantos01/qgis_mcp) (port 9876). Nodes are coloured by pressure,
>   pipes by velocity, on an OpenStreetMap basemap (`bridge/qgis_load_results.py`).
> - **Update EPANET** (a button in QGIS): sends edited junction elevations and base demands, and pipe
>   diameters, lengths, roughness and status back. EPANET-UI checks every value, changes nothing if one is
>   refused, runs the model again and comes to the front (`bridge/qgis_update_epanet.py`).
> - **Command channel**: started with `--remote`, EPANET-UI takes JSON commands on `127.0.0.1:9877` only
>   (`src/core/cmdhandlers.pas`). `bridge/epanet_mcp_server.py` offers them to Claude Code as MCP tools.
> - **3D view** of the hydraulic grade line and of single valves (Map Viewer > View > 3D). It is drawn from
>   EPANET results; it is not a CFD simulation.
> - Starts in a dark theme; building on Windows needs the MetaDarkStyle package.

EPANET is an industry-standard software package for modeling water distribution systems. It simulates the hydraulic and water quality behavior of a pressurized pipe network over an extended period of time. This project introduces a new user interface for EPANET that:
- offers a modern and simple design
- runs on Windows, Linux and MacOS
- uses the latest OWA EPANET engine (v2.3) that can model pressure dependent demands and FAVAD pipe leakage
- has full support for EPANET's multi-species water quality (MSX) extension
- can import data from GIS shapefiles, DXF CAD files, and CSV text files
- can use web mapping services to provide dynamic background basemaps
- has multiple reporting options for simulation results, including energy audits, variability plots, and fire flow analysis. 

EPANET-UI executables for both Windows and Linux can be downloaded from  [here](https://sites.google.com/view/epanet-ui).
Ongoing development of the OWA EPANET engine can be found at [OWA EPANET](https://github.com/openwateranalytics/epanet).
