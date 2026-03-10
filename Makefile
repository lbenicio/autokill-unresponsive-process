# ─────────────────────────────────────────────────────────────────────────────
# autokill-unresponsive-process — Makefile
# ─────────────────────────────────────────────────────────────────────────────

PRODUCT_NAME   := autokill-unresponsive-process
LAUNCHD_LABEL  := com.autokill.unresponsive

# Paths
INSTALL_DIR    := $(HOME)/.local/bin
INSTALL_PATH   := $(INSTALL_DIR)/$(PRODUCT_NAME)
PLIST_TEMPLATE := Plist/$(LAUNCHD_LABEL).plist
PLIST_DIR      := $(HOME)/Library/LaunchAgents
PLIST_PATH     := $(PLIST_DIR)/$(LAUNCHD_LABEL).plist
CONFIG_DIR     := $(HOME)/.config/autokill-unresponsive
CONFIG_FILE    := $(CONFIG_DIR)/config.json
LOG_DIR        := $(HOME)/.local/log/autokill-unresponsive
UID            := $(shell id -u)

# Build
BUILD_DIR      := .build
RELEASE_BIN    := $(BUILD_DIR)/release/$(PRODUCT_NAME)
DEBUG_BIN      := $(BUILD_DIR)/debug/$(PRODUCT_NAME)
SWIFT          := swift
SWIFTFORMAT    := swiftformat
SWIFTLINT      := swiftlint
SOURCES        := $(shell find Sources -name '*.swift' 2>/dev/null)

# ─────────────────────────────────────────────────────────────────────────────
# Default
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: all
all: build ## Build release binary (default)

# ─────────────────────────────────────────────────────────────────────────────
# Build
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: build
build: $(RELEASE_BIN) ## Build release binary

$(RELEASE_BIN): Package.swift $(SOURCES)
	$(SWIFT) build -c release

.PHONY: debug
debug: $(DEBUG_BIN) ## Build debug binary

$(DEBUG_BIN): Package.swift $(SOURCES)
	$(SWIFT) build -c debug

# ─────────────────────────────────────────────────────────────────────────────
# Install / Uninstall
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: install
install: build dirs plist config ## Build, install binary, register launchd agent
	@echo "→ Installing binary to $(INSTALL_PATH)"
	cp -f $(RELEASE_BIN) $(INSTALL_PATH)
	chmod 755 $(INSTALL_PATH)
	@echo "→ Loading launchd agent"
	@launchctl bootout gui/$(UID)/$(LAUNCHD_LABEL) 2>/dev/null || \
		launchctl unload $(PLIST_PATH) 2>/dev/null || true
	@launchctl bootstrap gui/$(UID) $(PLIST_PATH) 2>/dev/null || \
		launchctl load -w $(PLIST_PATH) 2>/dev/null || \
		echo "⚠  Could not auto-load agent. Log out and back in, or run: launchctl load -w $(PLIST_PATH)"
	@sleep 1
	@if launchctl list $(LAUNCHD_LABEL) >/dev/null 2>&1; then \
		echo "✔ Daemon is running"; \
	else \
		echo "⚠  Daemon does not appear to be running. Check: make log"; \
	fi
	@echo ""
	@echo "✔ Installation complete"
	@echo "  Binary : $(INSTALL_PATH)"
	@echo "  Plist  : $(PLIST_PATH)"
	@echo "  Config : $(CONFIG_FILE)"
	@echo "  Logs   : $(LOG_DIR)/"

.PHONY: dirs
dirs:
	@mkdir -p $(INSTALL_DIR) $(PLIST_DIR) $(CONFIG_DIR) $(LOG_DIR)

.PHONY: plist
plist: dirs
	@echo "→ Installing launchd plist"
	@sed \
		-e 's|__INSTALL_PATH__|$(INSTALL_DIR)|g' \
		-e 's|__LOG_DIR__|$(LOG_DIR)|g' \
		$(PLIST_TEMPLATE) > $(PLIST_PATH)

.PHONY: config
config: dirs
	@if [ ! -f "$(CONFIG_FILE)" ]; then \
		echo "→ Creating default config at $(CONFIG_FILE)"; \
		printf '{\n    "checkIntervalSeconds": 10,\n    "graceBeforeTermSeconds": 30,\n    "graceBeforeKillSeconds": 10,\n    "dryRun": false,\n    "notifyOnKill": true,\n    "maxKillsPerCycle": 5,\n    "excludedBundleIdentifiers": [],\n    "excludedProcessNames": []\n}\n' > $(CONFIG_FILE); \
	else \
		echo "→ Config already exists at $(CONFIG_FILE) — not overwriting"; \
	fi

.PHONY: uninstall
uninstall: stop ## Stop daemon, remove binary and plist (keeps config & logs)
	@echo "→ Removing launchd plist"
	@rm -f $(PLIST_PATH)
	@echo "→ Removing binary"
	@rm -f $(INSTALL_PATH)
	@echo ""
	@echo "✔ Uninstalled. Config and logs preserved at:"
	@echo "  $(CONFIG_DIR)/"
	@echo "  $(LOG_DIR)/"
	@echo "  Run 'make purge' to remove those too."

.PHONY: purge
purge: uninstall ## Uninstall and also remove config and logs
	@echo "→ Removing config directory"
	@rm -rf $(CONFIG_DIR)
	@echo "→ Removing log directory"
	@rm -rf $(LOG_DIR)
	@echo "✔ Fully purged"

# ─────────────────────────────────────────────────────────────────────────────
# Daemon management
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: start
start: ## Start the launchd agent
	@if launchctl list $(LAUNCHD_LABEL) >/dev/null 2>&1; then \
		echo "Daemon is already running"; \
	else \
		launchctl bootstrap gui/$(UID) $(PLIST_PATH) 2>/dev/null || \
			launchctl load -w $(PLIST_PATH) 2>/dev/null || \
			echo "⚠  Failed to start. Run 'make install' first."; \
		echo "✔ Daemon started"; \
	fi

.PHONY: stop
stop: ## Stop the launchd agent
	@launchctl bootout gui/$(UID)/$(LAUNCHD_LABEL) 2>/dev/null || \
		launchctl unload $(PLIST_PATH) 2>/dev/null || true
	@pkill -x $(PRODUCT_NAME) 2>/dev/null || true
	@echo "✔ Daemon stopped"

.PHONY: restart
restart: stop start ## Restart the launchd agent

.PHONY: reload
reload: ## Reload config without restarting (sends SIGHUP)
	@if pgrep -x $(PRODUCT_NAME) >/dev/null 2>&1; then \
		pkill -HUP -x $(PRODUCT_NAME); \
		echo "✔ Sent SIGHUP — config reloaded"; \
	else \
		echo "⚠  Daemon is not running"; \
	fi

.PHONY: status
status: ## Show whether the daemon is running
	@if launchctl list $(LAUNCHD_LABEL) >/dev/null 2>&1; then \
		echo "✔ Daemon is loaded in launchd"; \
		launchctl list $(LAUNCHD_LABEL); \
	else \
		echo "✖ Daemon is not loaded in launchd"; \
	fi
	@echo ""
	@if pgrep -x $(PRODUCT_NAME) >/dev/null 2>&1; then \
		echo "✔ Process is running (pid $$(pgrep -x $(PRODUCT_NAME)))"; \
	else \
		echo "✖ Process is not running"; \
	fi

# ─────────────────────────────────────────────────────────────────────────────
# Run / Test
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: run
run: build ## Run a single scan in dry-run + verbose mode
	$(RELEASE_BIN) --once --verbose --dry-run

.PHONY: run-live
run-live: build ## Run interactively in foreground (verbose, real kills)
	$(RELEASE_BIN) --verbose

.PHONY: run-debug
run-debug: debug ## Run debug build interactively (verbose, dry-run)
	$(DEBUG_BIN) --once --verbose --dry-run

.PHONY: test
test: ## Run Swift tests
	$(SWIFT) test

# ─────────────────────────────────────────────────────────────────────────────
# Lint / Format
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: lint
lint: ## Run swiftlint (if installed)
	@if command -v $(SWIFTLINT) >/dev/null 2>&1; then \
		$(SWIFTLINT) lint --quiet; \
	else \
		echo "⚠  swiftlint not found. Install: brew install swiftlint"; \
	fi

.PHONY: format
format: ## Run swiftformat (if installed)
	@if command -v $(SWIFTFORMAT) >/dev/null 2>&1; then \
		$(SWIFTFORMAT) Sources/; \
	else \
		echo "⚠  swiftformat not found. Install: brew install swiftformat"; \
	fi

.PHONY: format-check
format-check: ## Check formatting without modifying files
	@if command -v $(SWIFTFORMAT) >/dev/null 2>&1; then \
		$(SWIFTFORMAT) --lint Sources/; \
	else \
		echo "⚠  swiftformat not found. Install: brew install swiftformat"; \
	fi

# ─────────────────────────────────────────────────────────────────────────────
# Logs
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: log
log: ## Tail the daemon log file
	@if [ -f "$(LOG_DIR)/autokill.log" ]; then \
		tail -f $(LOG_DIR)/autokill.log; \
	else \
		echo "No log file found at $(LOG_DIR)/autokill.log"; \
		echo "Run 'make install' or 'make run' first."; \
	fi

.PHONY: log-system
log-system: ## Stream live entries from the unified system log
	log stream --predicate 'subsystem == "com.autokill.unresponsive"' --level debug

# ─────────────────────────────────────────────────────────────────────────────
# Clean
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: clean
clean: ## Remove build artifacts
	$(SWIFT) package clean
	rm -rf $(BUILD_DIR)

# ─────────────────────────────────────────────────────────────────────────────
# Help
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: help
help: ## Show this help
	@printf "\nUsage: make \033[1m<target>\033[0m\n\n"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""
