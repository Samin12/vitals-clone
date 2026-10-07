# VitalsClone

A SwiftUI menu-bar activity monitor modeled on [Vitals](https://vitalsmac.com). It was rebuilt from a static analysis of the shipped app using [REA](https://github.com/morluto/rea), and no original source code was used.

## Features
- Processes grouped by app, so each helper process counts toward its parent app
- Live CPU, memory, disk, network and GPU readings, with per-app GPU and network usage
- Dev projects with their open ports, plus detection of idle dev servers
- A list of apps keeping the Mac awake
- Insights for sustained CPU, growing memory, and heavy network or disk use
- Quit and Force Quit for apps, single processes and whole projects

## Build
```sh
./build-app.sh                 # builds build/VitalsClone.app
open build/VitalsClone.app
build/VitalsClone.app/Contents/MacOS/VitalsClone --dump   # print one sample and exit
```
The build script uses the Command Line Tools with the macOS 26.5 SDK. Requires macOS 15 or later.
