BINDIR ?= $(HOME)/.local/bin
RELEASE_FLAGS := -Doptimize=ReleaseFast -Dstrip=true
WEB_OUT ?= ../zig-out/web
WEB_PORT ?= 8027

.PHONY: release install-release memory-test memory-smoke memory-leaks web web-open web-serve web-clean

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

memory-test:
	zig build test --summary all

memory-smoke:
	zig build --summary all
	./zig-out/bin/zi --version

memory-leaks: memory-smoke
	@if command -v leaks >/dev/null 2>&1; then \
		leaks --atExit -- ./zig-out/bin/zi --version; \
	elif command -v valgrind >/dev/null 2>&1; then \
		valgrind --error-exitcode=1 --leak-check=full --show-leak-kinds=all --track-origins=yes ./zig-out/bin/zi --version; \
	else \
		echo "Install macOS leaks or Linux valgrind for external leak checks."; \
		exit 1; \
	fi

web:
	@command -v zine >/dev/null 2>&1 || { \
		echo "zine is required to build the website."; \
		echo "Install it from https://github.com/kristoff-it/zine/releases or run:"; \
		echo "  curl -L https://github.com/kristoff-it/zine/releases/download/v0.11.2/aarch64-macos.zip -o /tmp/zine.zip"; \
		echo "  unzip -o /tmp/zine.zip -d /tmp/zine && install -m 0755 /tmp/zine/zine \"$(BINDIR)/zine\""; \
		exit 1; \
	}
	cd website && zig build web -p "$(WEB_OUT)"
	@echo "Built website at zig-out/web"
	@echo "  /     -> zig-out/web/index.html"
	@echo "  /man  -> zig-out/web/man/index.html"

web-open: web
	@echo "Serving website at http://127.0.0.1:$(WEB_PORT)"
	@open "http://127.0.0.1:$(WEB_PORT)"
	cd "zig-out/web" && python3 -m http.server "$(WEB_PORT)" --bind 127.0.0.1

web-serve: web
	@echo "Serving website at http://127.0.0.1:$(WEB_PORT)"
	cd "zig-out/web" && python3 -m http.server "$(WEB_PORT)" --bind 127.0.0.1

web-clean:
	trash "zig-out/web" 2>/dev/null || rm -rf "zig-out/web"
