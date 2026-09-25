if vim.g.loaded_pair then return end
vim.g.loaded_pair = true
require('pair').setup()
