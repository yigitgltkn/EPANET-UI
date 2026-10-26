"""Start the QGIS MCP plugin's server as soon as QGIS has loaded.

Launch QGIS with this file so Claude can reach it without a click:

    qgis-ltr-bin.exe --code "D:\\Projeler\\Epanet_YG\\EPANET-UI\\bridge\\qgis_mcp_autostart.py"

QGIS started any other way is left alone: the server only listens on this
computer, but it lets local programs run Python inside QGIS, so it stays an
explicit choice made through this shortcut.
"""
from qgis.PyQt.QtCore import QTimer
from qgis.utils import iface, plugins

PLUGIN = "qgis_mcp_plugin"
RETRY_MS = 500
MAX_TRIES = 60          # plugins can take a while to load on a cold start
_tries = [0]


def _start_mcp_server():
    plugin = plugins.get(PLUGIN)
    if plugin is None or getattr(plugin, "action", None) is None:
        _tries[0] += 1
        if _tries[0] < MAX_TRIES:
            QTimer.singleShot(RETRY_MS, _start_mcp_server)
        else:
            iface.messageBar().pushWarning(
                "QGIS MCP", "Plugin not found: enable QGIS MCP in the Plugins menu and press Start Server.")
        return

    # Open the plugin's panel the same way its toolbar button does
    if plugin.dock_widget is None or not plugin.action.isChecked():
        plugin.action.trigger()
    dock = plugin.dock_widget
    if dock is not None and dock.server is None:
        dock.start_server()
    if dock is not None and dock.server is not None:
        iface.messageBar().pushSuccess("QGIS MCP", "Server running on port %d" % dock.server.port)


QTimer.singleShot(0, _start_mcp_server)
