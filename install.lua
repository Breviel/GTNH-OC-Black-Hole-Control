local shell = require("shell")
local filesystem = require("filesystem")
local term = require("term")

local baseUrl = "https://raw.githubusercontent.com/Breviel/GTNH-OC-Black-Hole-Control/main/"

local files = {
  "main.lua",
  "version.lua",
  "src/black-hole-controller.lua",
  "lib/component-discover-lib.lua",
  "lib/gui-lib.lua",
  "lib/gui-widgets/scroll-list.lua",
  "lib/list-lib.lua",
  "lib/logger-handler/discord-logger-handler-lib.lua",
  "lib/logger-handler/file-logger-handler-lib.lua",
  "lib/logger-handler/scroll-list-logger-handler-lib.lua",
  "lib/logger-lib.lua",
  "lib/program-lib.lua",
  "lib/state-machine-lib.lua",
}

local configFile = "config.lua"

shell.setWorkingDirectory("/home")

for _, file in ipairs(files) do
  local dir = filesystem.path("/home/" .. file)
  if dir and dir ~= "/home/" and not filesystem.exists(dir) then
    filesystem.makeDirectory(dir)
  end
  term.write("Downloading " .. file .. "\n")
  shell.execute("wget -fq " .. baseUrl .. file .. " " .. file)
end

if not filesystem.exists(configFile) then
  term.write("Downloading " .. configFile .. "\n")
  shell.execute("wget -fq " .. baseUrl .. configFile .. " " .. configFile)
end

term.write("Installation complete! Edit config.lua, then run 'main' to start.\n")
