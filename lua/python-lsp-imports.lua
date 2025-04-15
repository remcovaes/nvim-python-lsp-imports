---@class MyModule
local M = {}

local servers = {}

---@class lspimport.Server
---@field is_unresolved_import_error fun(diagnostic: vim.Diagnostic): boolean
---@field is_auto_import_completion_item fun(item: any): boolean

local function pyright_server()
  -- Reports undefined variables as unresolved imports.
  ---@param diagnostic vim.Diagnostic
  ---@return boolean
  local function is_unresolved_import_error(diagnostic)
    return diagnostic.code == "reportUndefinedVariable"
  end

  --- Returns "Auto-import" menu item as import completion.
  ---@param item any
  ---@return boolean
  local function is_auto_import_completion_item(item)
    return item.menu == "Auto-import"
  end

  return {
    is_unresolved_import_error = is_unresolved_import_error,
    is_auto_import_completion_item = is_auto_import_completion_item,
  }
end

---Returns a server class.
---@param diagnostic vim.Diagnostic
---@return lspimport.Server|nil
function servers.get_server(diagnostic)
  if diagnostic.source == "Pyright" then
    return pyright_server()
  end
end

local LspImport = {}

---@return vim.Diagnostic[]
local get_unresolved_import_errors = function()
  local line, _ = unpack(vim.api.nvim_win_get_cursor(0))
  local diagnostics = vim.diagnostic.get(0, { lnum = line - 1, severity = vim.diagnostic.severity.ERROR })
  if vim.tbl_isempty(diagnostics) then
    return {}
  end
  ---@param diagnostic vim.Diagnostic
  return vim.tbl_filter(function(diagnostic)
    local server = servers.get_server(diagnostic)
    if server == nil then
      return false
    end
    return server.is_unresolved_import_error(diagnostic)
  end, diagnostics)
end

---@param diagnostics vim.Diagnostic[]
---@return vim.Diagnostic|nil
local get_diagnostic_under_cursor = function(diagnostics)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]
  for _, d in ipairs(diagnostics) do
    if d.lnum <= row and d.col <= col and d.end_lnum >= row and d.end_col >= col then
      return d
    end
  end
  return nil
end

---@param result vim.lsp.CompletionResult Result of `textDocument/completion`
---@param prefix string prefix to filter the completion items
---@return table[]
local lsp_to_complete_items = function(result, prefix)
  if vim.fn.has("nvim-0.10.0") == 1 then
    -- TODO: use another function once it's available in public API.
    -- See: https://neovim.io/doc/user/deprecated.html#vim.lsp.util.text_document_completion_list_to_complete_items()
    return vim.lsp.completion._lsp_to_complete_items(result, prefix)
  else
    return require("vim.lsp.util").text_document_completion_list_to_complete_items(result, prefix)
  end
end

---@param server lspimport.Server
---@param result lsp.CompletionList|lsp.CompletionItem[] Result of `textDocument/completion`
---@param unresolved_import string
---@return table[]
local get_auto_import_complete_items = function(server, result, unresolved_import)
  local items = lsp_to_complete_items(result, unresolved_import)
  if vim.tbl_isempty(items) then
    return {}
  end
  return vim.tbl_filter(function(item)
    return item.word == unresolved_import
      and item.user_data
      and item.user_data.nvim
      and item.user_data.nvim.lsp.completion_item
      and item.user_data.nvim.lsp.completion_item.labelDetails
      and item.user_data.nvim.lsp.completion_item.labelDetails.description
      and item.user_data.nvim.lsp.completion_item.additionalTextEdits
      and not vim.tbl_isempty(item.user_data.nvim.lsp.completion_item.additionalTextEdits)
      and server.is_auto_import_completion_item(item)
  end, items)
end

---@param item any|nil
---@param bufnr integer
local resolve_import = function(item, bufnr)
  if item == nil then
    return
  end
  local text_edits = item.user_data.nvim.lsp.completion_item.additionalTextEdits
  vim.lsp.util.apply_text_edits(text_edits, bufnr, "utf-8")
end

---@param item any
local format_import = function(item)
  return item.abbr .. " " .. item.kind .. " " .. item.user_data.nvim.lsp.completion_item.labelDetails.description
end

---@param diagnostic vim.Diagnostic
local lsp_completion = function(diagnostic)
  local unresolved_import = vim.api.nvim_buf_get_text(
    diagnostic.bufnr,
    diagnostic.lnum,
    diagnostic.col,
    diagnostic.end_lnum,
    diagnostic.end_col,
    {}
  )
  if vim.tbl_isempty(unresolved_import) then
    vim.notify("cannot find diagnostic symbol")
    return
  end
  local server = servers.get_server(diagnostic)
  if server == nil then
    vim.notify("cannot find server implemantion for lsp import")
    return
  end
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = diagnostic.lnum, character = diagnostic.end_col },
  }
  local results = vim.lsp.buf_request_sync(diagnostic.bufnr, "textDocument/completion", params)
  local all_items = {}

  for client_id, result in pairs(results or {}) do
    if not vim.tbl_isempty(result.result or {}) then
      local items = get_auto_import_complete_items(server, result.result, unresolved_import[1])
      if not vim.tbl_isempty(items) then
        vim.list_extend(all_items, items)
      end
    end
  end

  if vim.tbl_isempty(all_items) then
    vim.notify("no import found for " .. unresolved_import[1])
  else
    local null_ls_items = {}
    for _, item in ipairs(all_items) do
      table.insert(null_ls_items, {
        title = format_import(item),
        action = function()
          resolve_import(item, diagnostic.bufnr)
        end,
        -- title = format_import(item),
        -- action = function()
        -- 	resolve_import(item, diagnostic.bufnr)
        -- end,
      })
    end

    return null_ls_items
  end
end

M.get_import_suggestions = function()
  local diagnostics = get_unresolved_import_errors()
  if vim.tbl_isempty(diagnostics) then
    vim.notify("no unresolved import error")
    return
  end
  local diagnostic = get_diagnostic_under_cursor(diagnostics)
  local res = lsp_completion(diagnostic or diagnostics[1])
  return res
end

M.setup = function()
  local null_ls = require("null-ls")

  return {
    name = "Import suggestions",
    method = null_ls.methods.CODE_ACTION,
    filetypes = {},
    generator = {
      fn = function(context)
        local actions = {}
        local imports = require("config.lspimport").import()

        if imports then
          for _, import in ipairs(imports) do
            table.insert(actions, {
              title = import.title,
              action = import.action,
            })
          end
        end
        return actions
      end,
    },
  }
end

return M
