@echo off
REM Paradise Audio - Windows VST3 build
REM Requires: Visual Studio 2022 (Desktop C++), CMake 3.22+, Git
cmake -B build -G "Visual Studio 17 2022" -A x64
cmake --build build --config Release
echo.
echo Built VST3s are under build\src\^<Plugin^>\<Plugin>_artefacts\Release\VST3\
echo Copy them to C:\Program Files\Common Files\VST3\
