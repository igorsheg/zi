BINDIR ?= $(HOME)/.local/bin
RELEASE_FLAGS := -Doptimize=ReleaseFast -Dstrip=true

.PHONY: release install-release

release:
	zig build $(RELEASE_FLAGS)

install-release: release
	mkdir -p "$(BINDIR)"
	install -m 0755 "zig-out/bin/zi" "$(BINDIR)/zi"
	@case ":$(PATH):" in \
		*:$(BINDIR):*) echo "Installed zi to $(BINDIR)/zi" ;; \
		*) echo "Installed zi to $(BINDIR)/zi"; \
		   echo "Note: $(BINDIR) is not currently in PATH"; \
		   echo "Add this to your shell profile:"; \
		   echo "  export PATH=\"$(BINDIR):\$$PATH\"" ;; \
	esac
