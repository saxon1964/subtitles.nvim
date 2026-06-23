if vim.g.loaded_subsync then return end
vim.g.loaded_subsync = true

require('subsync').setup()
