local oil = require("oil")
local test_util = require("tests.test_util")

describe("window options", function()
  after_each(function()
    test_util.reset_editor()
  end)

  it("Restores window options on close", function()
    vim.cmd.edit({ args = { "README.md" } })
    oil.open()
    assert.equals("no", vim.o.signcolumn)
    oil.close()
    assert.equals("auto", vim.o.signcolumn)
  end)

  it("Restores window options on edit", function()
    oil.open()
    assert.equals("no", vim.o.signcolumn)
    vim.cmd.edit({ args = { "README.md" } })
    assert.equals("auto", vim.o.signcolumn)
  end)

  it("Restores window options on split <filename>", function()
    oil.open()
    assert.equals("no", vim.o.signcolumn)
    vim.cmd.split({ args = { "README.md" } })
    assert.equals("auto", vim.o.signcolumn)
  end)

  it("Restores window options on split", function()
    oil.open()
    assert.equals("no", vim.o.signcolumn)
    vim.cmd.split()
    vim.cmd.edit({ args = { "README.md" } })
    assert.equals("auto", vim.o.signcolumn)
  end)
end)
