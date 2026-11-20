@echo off
rem exosuitctl: exohost's control-plane command line (docs/design/exosuitctl/TDD-exosuit-ctl.md section 8.2); exohost run with --ctl.
python "%~dp0exohost.py" --ctl %*
