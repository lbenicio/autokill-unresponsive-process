# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-03-09

### Features

- Externalize Info.plist generation to a template file and introduce versioning variables in the Makefile.
- Improve screen selection overlay with target screen detection, coordinate conversion, and user instructions including selection dimensions.
- Implement  to report real-time bot feature status like hunger and protection zone presence.
- Implement Protection Zone detection to pause bot actions and add related configuration and UI.
- Replace  with a global  for more general buff detection and update its configuration and UI.
- Add a default food icon to the app configuration and copy resources into the app bundle during build.
- Implement screen area selection with live preview in automation settings, add new image assets, and refactor the automation configuration UI.
- introduce  to detect target application state and window, enabling targeted screen reading, input, and UI status display.
- Add SwiftUI application with configurable auto-food feature, replacing command-line runner and refactoring bot logic and agents.
- implement initial bot application structure with core logic, screen reading, and input simulation.

### Chores

- bump actions/checkout from 5 to 6
- bump actions/upload-artifact from 5 to 7
- bump actions/download-artifact from 6 to 8

### Other Changes

- Implement two-layer heal cooldown detection model
- Add GitHub templates, docs, and cooldown detection updates
- Add cooldown detection feature with tests and UI updates
- Add integration tests for icon detection using real screenshots
- Add test image with 5 buffs for full window scenario
- Update test images for buffs bar and preview examples
- Add example images for full window with 0-3 buffs
- Add auto-detect for buffs area in Tibia window
- Update CONTEXT.md and TASK.md for completed robustness tasks
- Add BotTests target and unit tests for core and pixel matching
- Add project context, TODO, logging, and accessibility checks
- refactor: update BUNDLE_IDENTIFIER to use APP_NAME variable for dynamic assignment
