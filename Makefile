PREFIX        ?= $(HOME)/.local
BINDIR        := $(PREFIX)/bin
SCRIPT        := ankh

ZSH_COMP_DIR  ?= $(HOME)/.local/share/zsh/site-functions
BASH_COMP_DIR ?= $(HOME)/.local/share/bash-completion/completions
FISH_COMP_DIR ?= $(HOME)/.config/fish/completions

.PHONY: install install-completions lint test

install:
	@mkdir -p "$(BINDIR)"
	@cp -- "$(SCRIPT)" "$(BINDIR)/$(SCRIPT)" && chmod +x "$(BINDIR)/$(SCRIPT)"
	@echo "Installed $(BINDIR)/$(SCRIPT)."
	@case ":$(PATH):" in \
	  *:$(BINDIR):*) ;; \
	  *) printf 'Note: %s is not in your PATH. Add to your shell config:\n  export PATH="%s:$$PATH"\n' \
	       "$(BINDIR)" "$(BINDIR)" ;; \
	esac

install-completions:
	@mkdir -p "$(ZSH_COMP_DIR)"  && cp comp/zsh/_ankh     "$(ZSH_COMP_DIR)/_ankh"     && echo "Installed zsh completions to $(ZSH_COMP_DIR)."
	@mkdir -p "$(BASH_COMP_DIR)" && cp comp/bash/ankh     "$(BASH_COMP_DIR)/ankh"     && echo "Installed bash completions to $(BASH_COMP_DIR)."
	@mkdir -p "$(FISH_COMP_DIR)" && cp comp/fish/ankh.fish "$(FISH_COMP_DIR)/ankh.fish" && echo "Installed fish completions to $(FISH_COMP_DIR)."

lint:
	shellcheck ankh ankh-verify install.sh tests/run.sh comp/bash/ankh
	bash -n ankh
	bash -n ankh-verify
	bash -n comp/bash/ankh
	zsh -n comp/zsh/_ankh
	@if command -v fish >/dev/null 2>&1; then fish -n comp/fish/ankh.fish; else echo "fish not installed: skipped"; fi

test:
	bash tests/run.sh
