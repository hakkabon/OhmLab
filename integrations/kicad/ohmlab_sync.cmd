@echo off
rem Windows launcher for the OhmLab KiCad action plugin.
rem Point the plugin.json entrypoint at this file instead of ohmlab_sync.py.
python "%~dp0ohmlab_sync.py" %*
