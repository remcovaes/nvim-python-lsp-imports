# Nvim-python-lsp-imports

Aims to bring lsp import functionality to Neovim code action for Python.

## Setup

For Lazy:
```lua
return {
	"nvimtools/none-ls.nvim",
	config = function()
		local lspImportSource = require("python-lsp-imports").setup()

		require("null-ls").setup({
			sources = {
				lspImportSource,
			},
		})
	end,
}
```

The plugin works by pretending to be an LSP that has Code action capabilities.
The thing is does is check for if a symbol under the cursor is undefined, and look for imports if code action is requested.

