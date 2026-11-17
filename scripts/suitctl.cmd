@echo off
rem suitctl: suit's control-plane command line (docs/design/suitctl/TDD-exosuit-ctl.md section 8.2); suit run with --ctl.
python "%~dp0suit.py" --ctl %*
