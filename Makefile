# Convenience wrapper for installing an already-built Meson target.

BUILD_DIR ?= build
PREFIX ?= $(shell brew --prefix 2>/dev/null || echo /usr/local)
BINDIR ?= $(PREFIX)/bin
DESTDIR ?=

.PHONY: install


install:
	@test -x "$(BUILD_DIR)/mpv" || { \
		echo "No compiled mpv at $(BUILD_DIR)/mpv; run 'meson compile -C $(BUILD_DIR) mpv' first." >&2; \
		exit 1; \
	}
	@mkdir -p "$(DESTDIR)$(BINDIR)"
	install -m 755 "$(BUILD_DIR)/mpv" "$(DESTDIR)$(BINDIR)/mpv"
