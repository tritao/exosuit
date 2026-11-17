@echo off
rem exohostctl: exohost's control-plane command line (docs/design/exohostctl/TDD-exosuit-ctl.md section 8.2); exohost run with --ctl.
python "%~dp0exohost.py" --ctl %*
