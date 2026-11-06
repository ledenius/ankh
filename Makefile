PREFIX        ?= $(HOME)/.local
BINDIR        := $(PREFIX)/bin
SCRIPT        := ankh

ZSH_COMP_DIR  ?= $(HOME)/.local/share/zsh/site-functions
BASH_COMP_DIR ?= $(HOME)/.local/share/bash-completion/completions
FISH_COMP_DIR ?= $(HOME)/.config/fish/completions

SIGNER        ?= BF986D6657FB89DA22D54E2893FA6B4846DAAF92

.PHONY: install install-completions lint test dist sign

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

# A release's files: the two scripts and their checksums, then a detached
# signature over the checksums (gpg-agent asks for the passphrase).
dist:
	@rm -rf dist && mkdir dist
	@cp ankh ankh-verify dist/
	@cd dist && sha256sum ankh ankh-verify >SHA256SUMS
	@cat dist/SHA256SUMS

sign: dist
	gpg --local-user "$(SIGNER)!" --armor --detach-sign --output dist/SHA256SUMS.asc dist/SHA256SUMS
	gpg --verify dist/SHA256SUMS.asc dist/SHA256SUMS
