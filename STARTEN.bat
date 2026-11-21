@echo off
rem Startet das Notizbuch. Alle Eintraege werden in notizbuch.json in diesem Ordner gespeichert.
start "Notizbuch" /min powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0notizbuch-server.ps1"
