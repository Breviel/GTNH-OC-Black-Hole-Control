local component = require("component")
local event = require("event")
local computer = require("computer")

local stateMachineLib = require("lib.state-machine-lib")
local componentDiscoverLib = require("lib.component-discover-lib")

---@class BlackHoleControllerConfig
---@field blackHoleSeedsTransposerAddress string
---@field blackHoleSeedInputBusSide integer
---@field ioPortTransposerAddress string
---@field meDriveSide integer
---@field meIoPortSide integer
---@field meInterfaceAddress string
---@field saveRecipeMode boolean
---@field maxCyclesCount integer

-- Internal item name of the AE2FC Fluid Encoded Pattern (the pink one).
-- Only this pattern type is accepted by AE2FluidCraft-Rework's OC driver
-- (DriverOCPatternEditor.validPattern) for setInterfacePatternInput/Output.
--
-- In particular, the GTNH AE2 fork "Encoded Ultimate Pattern"
-- (appliedenergistics2:item.ItemEncodedUltimatePattern), which is now the
-- default output of the Pattern Terminal in recent GTNH dailies, is NOT
-- accepted and will cause "Not Fluid Encoded pattern!" to be thrown.
local FLUID_ENCODED_PATTERN_NAME = "ae2fc:fluid_encoded_pattern"

local blackHoleController = {}

---Convert number to string with commas
---@param number number
---@return string
local function numWithCommas(number)
  return tostring(math.floor(number)):reverse():gsub("(%d%d%d)","%1,"):gsub(",(%-?)$","%1"):reverse()
end

---Crate new BlackHoleController object from config
---@param config BlackHoleControllerConfig
---@return BlackHoleController
function blackHoleController:newFormConfig(config)
  return self:new(config.blackHoleSeedsTransposerAddress,
    config.blackHoleSeedInputBusSide,
    config.ioPortTransposerAddress,
    config.meDriveSide,
    config.meIoPortSide,
    config.meInterfaceAddress,
    config.saveRecipeMode,
    config.maxCyclesCount)
end

---Crate new BlackHoleController object
---@param blackHoleSeedsTransposerAddress string
---@param blackHoleSeedInputBusSide integer
---@param ioPortTransposerAddress string
---@param meDriveSide integer
---@param meIoPortSide integer
---@param meInterfaceAddress string
---@param saveRecipeMode boolean
---@param maxCyclesCount integer
---@return BlackHoleController
function blackHoleController:new(
  blackHoleSeedsTransposerAddress,
  blackHoleSeedInputBusSide,
  ioPortTransposerAddress,
  meDriveSide,
  meIoPortSide,
  meInterfaceAddress,
  saveRecipeMode,
  maxCyclesCount)

  ---@class BlackHoleController
  local obj = {}

  obj.craftingInputsProxies = {}

  obj.controllerProxy = nil
  obj.blackHoleSeedsTransposerProxy = nil
  obj.meInterfaceProxy = nil

  obj.blackHoleSeedInputBusSide = blackHoleSeedInputBusSide

  obj.meDriveSide = meDriveSide
  obj.meIoPortSide = meIoPortSide

  obj.saveRecipeMode = saveRecipeMode

  obj.maxTimer = 85
  obj.maxCycleTimer = 25
  obj.maxCyclesCount = maxCyclesCount

  obj.database = component.database
    
  ---@type table<string, TransposerItemStorageDescriptor>
  obj.transposerItems = {}
  obj.fakeRecipeName = ""

  obj.stateMachine = stateMachineLib:new()

  ---Init
  function obj:init()
    self:discoverComponents()
    self:findTransposerItem(self.blackHoleSeedsTransposerProxy, {"Black Hole Seed", "Black Hole Collapser"})

    self:fillDatabase()
    self:clearPattern()

    self.stateMachine.data.spaceTimePerCraftCount = self:calculateSpaceTimeCount(self.maxCyclesCount)

    self.stateMachine.states.idle = self.stateMachine:createState("Idle")
    self.stateMachine.states.idle.init = function()
      self.stateMachine.data.startTime = nil
      self.stateMachine.data.cycleStartTime = nil
      self.stateMachine.data.currentCycle = 0
      self.stateMachine.data.currentTimer = 0
      self.stateMachine.data.currentCycleTimer = 0
      self.stateMachine.data.notifyNotEnoughSpaceTime = false

      if self.saveRecipeMode == true or self.maxCyclesCount ~= 0 then
        self:removeExcessSpacetime()
      end
    end
    self.stateMachine.states.idle.update = function()
      if self.controllerProxy.getWorkMaxProgress() == 0 then
        if self:hasItems() == true and self.controllerProxy.isWorkAllowed() then
          if self:hasSeeds() == true then
            if self:hasEnoughSpacetime(self.stateMachine.data.spaceTimePerCraftCount) then
              self.stateMachine:setState(self.stateMachine.states.openBlackHole)
              return
            elseif self.stateMachine.data.notifyNotEnoughSpaceTime == false then
              self.stateMachine.data.notifyNotEnoughSpaceTime = true
              event.push("log_warning", "Not enough Space Time for craft. Need: "..numWithCommas(self.stateMachine.data.spaceTimePerCraftCount))
            end

            os.sleep(3)
          end
        end
      end
    end

    self.stateMachine.states.openBlackHole = self.stateMachine:createState("Open Black Hole")
    self.stateMachine.states.openBlackHole.init = function()
      self:openBlackHole()
    end
    self.stateMachine.states.openBlackHole.update = function()
      if self.blackHoleSeedsTransposerProxy.getSlotStackSize(self.blackHoleSeedInputBusSide, 1) == 0 then
        self.stateMachine.data.startTime = computer.uptime() - 1
        self.stateMachine.data.currentCycle = 0
        self.stateMachine:setState(self.stateMachine.states.waitFreeCraft)
      end
    end

    self.stateMachine.states.waitFreeCraft = self.stateMachine:createState("Wait Free Craft")
    self.stateMachine.states.waitFreeCraft.update = function()
      if self.stateMachine.data.currentTimer >= self.maxTimer then
        if self.maxCyclesCount ~= 0 and (self:hasItems() == true or self:getCraftTimeRemained() ~= 0) then
          self.stateMachine:setState(self.stateMachine.states.addSpaceTime)
        else
          if self:getCraftTimeRemained() > self:getStabilityTimeRemained() and self.saveRecipeMode == true then
            self.stateMachine:setState(self.stateMachine.states.saveRecipe)
          else
            self.stateMachine:setState(self.stateMachine.states.collapseBlackHole)
          end
        end
      end
    end

    self.stateMachine.states.addSpaceTime = self.stateMachine:createState("Add Space Time")
    self.stateMachine.states.addSpaceTime.init = function()
      self.stateMachine.data.cycleStartTime = computer.uptime()
      self.stateMachine.data.currentCycleTimer = 0
      self.stateMachine.data.currentCycle = self.stateMachine.data.currentCycle + 1

      local spacetimeCount = self:calculateSpaceTimeByCycleCount(self.stateMachine.data.currentCycle)
      self.stateMachine.data.requestCount = self:encodePattern(spacetimeCount)
    end
    self.stateMachine.states.addSpaceTime.update = function()
      if self:requestFakeRecipe(self.stateMachine.data.requestCount) == true or self:hasFakeRecipe() == true then
        self.stateMachine:setState(self.stateMachine.states.waitSpaceTime)
      else
        self.stateMachine.data.errorMessage = "Cant request craft: "..self.fakeRecipeName
        self.stateMachine:setState(self.stateMachine.states.error)
      end
    end

    self.stateMachine.states.waitSpaceTime = self.stateMachine:createState("Wait Space Time")
    self.stateMachine.states.waitSpaceTime.update = function ()
      if self.controllerProxy.getWorkMaxProgress() == 0 and self:hasItems() == false then
          self.stateMachine:setState(self.stateMachine.states.collapseBlackHole)
      elseif self.stateMachine.data.currentCycleTimer >= self.maxCycleTimer then
        if self.stateMachine.data.currentCycle < self.maxCyclesCount then
          self.stateMachine:setState(self.stateMachine.states.addSpaceTime)
        elseif self.saveRecipeMode == true and self:getCraftTimeRemained() > self:getStabilityTimeRemained() then
          self.stateMachine:setState(self.stateMachine.states.saveRecipe)
        else
          self.stateMachine:setState(self.stateMachine.states.collapseBlackHole)
        end
      end
    end

    self.stateMachine.states.saveRecipe = self.stateMachine:createState("Save Recipe")
    self.stateMachine.states.saveRecipe.init = function()
      local secondsRemained = math.floor(self:getCraftTimeRemained() - self:getStabilityTimeRemained())

      local needCycles = math.floor(secondsRemained / 30) + self.stateMachine.data.currentCycle
      local needTime = math.floor(secondsRemained % 30)

      local needSpaceTime = 0

      if needCycles ~= self.stateMachine.data.currentCycle then
        needSpaceTime = needSpaceTime + self:calculateSpaceTimeCount(needCycles, self.stateMachine.data.currentCycle)
      end

      needSpaceTime = needSpaceTime + self:calculateSpaceTimeByCycleCount(needCycles + 1, needTime)

      event.push("log_info", "[Save mode] Need:"..secondsRemained.." Added spacetime: "..numWithCommas(needSpaceTime));

      self.stateMachine.data.requestCount = self:encodePattern(needSpaceTime)
    end
    self.stateMachine.states.saveRecipe.update = function()
      if self:requestFakeRecipe(self.stateMachine.data.requestCount) == true or self:hasFakeRecipe() == true then
        self.stateMachine:setState(self.stateMachine.states.collapseBlackHole)
      else
        self.stateMachine.data.errorMessage = "Cant request craft: "..self.fakeRecipeName
        self.stateMachine:setState(self.stateMachine.states.error)
      end
    end

    self.stateMachine.states.collapseBlackHole = self.stateMachine:createState("Collapse Black Hole")
    self.stateMachine.states.collapseBlackHole.init = function()
      self:collapseBlackHole()
      self.stateMachine:setState(self.stateMachine.states.waitEnd)
    end

    self.stateMachine.states.waitEnd = self.stateMachine:createState("Wait end")
    self.stateMachine.states.waitEnd.update = function()
      if self.controllerProxy.getWorkMaxProgress() == 0 then
        self.stateMachine:setState(self.stateMachine.states.idle)
      end
    end

    self.stateMachine.states.error = self.stateMachine:createState("Error")
    self.stateMachine.states.error.init = function()
      self:collapseBlackHole()

      self.stateMachine.data.startTime = nil
      self.stateMachine.data.cycleStartTime = nil

      while self:tryCancelFakeRecipe() == false do
        os.sleep(0.1)
      end

      event.push("log_error", self.stateMachine.data.errorMessage)
      event.push("log_info","&red;Press Enter to confirm")

      self.stateMachine.data.errorMessage = nil
    end

    self.stateMachine:setState(self.stateMachine.states.idle)
  end

  ---Loop
  function obj:loop()
    if self.stateMachine.data.startTime ~= nil then
      self.stateMachine.data.currentTimer = self:getCurrentTimerTime(self.stateMachine.data.startTime)
    end

    if self.stateMachine.data.cycleStartTime ~= nil then
      self.stateMachine.data.currentCycleTimer = self:getCurrentTimerTime(self.stateMachine.data.cycleStartTime)
    end

    self.stateMachine:update()
  end

  --Reset error
  function obj:resetError()
    if self.stateMachine.currentState == self.stateMachine.states.error then
      self.stateMachine:setState(self.stateMachine.states.waitEnd)
    end
  end

  ---Get controller state
  ---@return number
  ---@return number
  ---@return number
  function obj:getState()
    return self.stateMachine.data.currentTimer, self.stateMachine.data.currentCycleTimer, self.stateMachine.data.currentCycle
  end

  ---Discover controller components
  ---@private
  function obj:discoverComponents()
    self.controllerProxy = componentDiscoverLib.discoverGtMachine("multimachine.blackholecompressor")

    if self.controllerProxy == nil then
      error("Pseudostable Black Hole Containment Field not found")
    end

    self.craftingInputsProxies = componentDiscoverLib.discoverGtMachines("hatch.crafting_input")

    if next(self.controllerProxy) == nil then
      error("Crafting inputs not found")
    end

    self.fakeRecipeName = "Fake recipe "..self.database.address:sub(0, 8)

    self.blackHoleSeedsTransposerProxy = componentDiscoverLib.discoverProxy(
      blackHoleSeedsTransposerAddress,
      "Black hole seed transposer",
      "transposer")

    -- The ME Dual Interface registers as "fluid_interface" in OpenComputers,
    -- not "me_interface". Using the correct component type here.
    self.meInterfaceProxy = componentDiscoverLib.discoverProxy(
      meInterfaceAddress,
      "ME interface",
      "fluid_interface")

    self.ioPortTransposer = componentDiscoverLib.discoverProxy(
      ioPortTransposerAddress,
      "ME IO Port Transposer",
      "transposer")
  end

  ---Find Transposer Item
  ---@param proxy transposer
  ---@param itemLabels string[]
  ---@private
  function obj:findTransposerItem(proxy, itemLabels)
    local result, skipped = componentDiscoverLib.discoverTransposerItemStorage(proxy, itemLabels, {self.blackHoleSeedInputBusSide})

    if #skipped ~= 0 then
      error("Can't find items: "..table.concat(skipped, ", "))
    end

    for key, value in pairs(result) do
      self.transposerItems[key] = value
    end
  end

  ---Fill database
  ---@private
  function obj:fillDatabase()
    self.database.set(1, "minecraft:paper", 0, "{display:{Name:\""..self.fakeRecipeName.."\"}}")
    self.database.set(2, "ae2fc:fluid_drop", 0, "{Fluid:molten.spacetime}")
  end

  ---Validate that the pattern in slot 1 of the ME Interface is a Fluid
  ---Encoded Pattern (pink). Recent GTNH daily releases default the Pattern
  ---Terminal to encode "Encoded Ultimate Pattern"
  ---(appliedenergistics2:item.ItemEncodedUltimatePattern) which is rejected
  ---by AE2FluidCraft-Rework's OC driver and breaks every subsequent
  ---setInterfacePatternInput / setInterfacePatternOutput call with the
  ---cryptic message "Not Fluid Encoded pattern!".
  ---
  ---This helper detects the situation early and surfaces an actionable error.
  ---@param pattern table
  ---@private
  function obj:assertFluidEncodedPattern(pattern)
    local name = pattern.name

    if name == nil then
      return
    end

    if name == FLUID_ENCODED_PATTERN_NAME then
      return
    end

    if name:find("ItemEncodedUltimatePattern", 1, true) ~= nil
       or name:find("EncodedUltimatePattern", 1, true) ~= nil then
      error(
        "The pattern in the ME Interface is an 'Encoded Ultimate Pattern'. " ..
        "Recent GTNH dailies make this the default output of the Pattern Terminal, " ..
        "but this program requires a pink 'Fluid Encoded Pattern' from the AE2FC " ..
        "Fluid Pattern Encoder / Fluid Pattern Terminal. " ..
        "Please replace the pattern in the interface and restart the program."
      )
    end

    if name:find("ItemEncodedPattern", 1, true) ~= nil then
      error(
        "The pattern in the ME Interface is a regular 'Encoded Pattern' " ..
        "(not the pink Fluid Encoded one). This program needs a Fluid Encoded Pattern " ..
        "(ae2fc:fluid_encoded_pattern). Please replace it and restart the program."
      )
    end
  end

  ---Clear inputs and outputs of the fake pattern.
  ---Iterates over all 9 slots using hardcoded integer literals to avoid the
  ---OC serialisation layer returning string keys from getInterfacePattern,
  ---which would cause "bad argument #2 (integer expected, got string)".
  ---@private
  function obj:clearPattern()
    local pattern = self.meInterfaceProxy.getInterfacePattern(1)

    if pattern == nil then
      error("No pattern in Interface")
    end

    self:assertFluidEncodedPattern(pattern)

    self.meInterfaceProxy.clearInterfacePatternOutput(1, 1)
    self.meInterfaceProxy.clearInterfacePatternOutput(1, 2)
    self.meInterfaceProxy.clearInterfacePatternOutput(1, 3)
    self.meInterfaceProxy.clearInterfacePatternOutput(1, 4)
    self.meInterfaceProxy.clearInterfacePatternOutput(1, 5)
    self.meInterfaceProxy.clearInterfacePatternOutput(1, 6)
    self.meInterfaceProxy.clearInterfacePatternOutput(1, 7)
    self.meInterfaceProxy.clearInterfacePatternOutput(1, 8)
    self.meInterfaceProxy.clearInterfacePatternOutput(1, 9)

    self.meInterfaceProxy.clearInterfacePatternInput(1, 1)
    self.meInterfaceProxy.clearInterfacePatternInput(1, 2)
    self.meInterfaceProxy.clearInterfacePatternInput(1, 3)
    self.meInterfaceProxy.clearInterfacePatternInput(1, 4)
    self.meInterfaceProxy.clearInterfacePatternInput(1, 5)
    self.meInterfaceProxy.clearInterfacePatternInput(1, 6)
    self.meInterfaceProxy.clearInterfacePatternInput(1, 7)
    self.meInterfaceProxy.clearInterfacePatternInput(1, 8)
    self.meInterfaceProxy.clearInterfacePatternInput(1, 9)

    self.meInterfaceProxy.setInterfacePatternOutput(1, 1, self.database.address, 1, 1)
  end

  ---Check if crafting inputs has items for craft
  ---@private
  function obj:hasItems()
    for _, proxy in pairs(self.craftingInputsProxies) do
      local sensorInformation = proxy.getSensorInformation()

      if sensorInformation[2] ~= nil then
        local startIndex = string.match(sensorInformation[2], "Internal Inventory:") ~= nil and 3 or 4
        local endIndex = #sensorInformation

        for i = startIndex, endIndex, 1 do
          if string.match(sensorInformation[i], "Slot") == nil then
            return true
          end
        end
      end
    end

    return false
  end

  ---Check if interface has seeds to craft
  ---@return boolean
  ---@private
  function obj:hasSeeds()
    for _, value in pairs(self.transposerItems) do
      local slot = self.blackHoleSeedsTransposerProxy.getStackInSlot(value.side, value.slot)

      if slot == nil or slot.size < 1 then
        return false
      end
    end

    return true
  end

  ---Check if ae has enough space time for craft
  ---@param spaceTimeCount integer
  ---@return boolean
  function obj:hasEnoughSpacetime(spaceTimeCount)
    local fluids = obj.meInterfaceProxy.getFluidsInNetwork()

    for _, value in pairs(fluids) do
      if value.name == "molten.spacetime" and value.amount >= spaceTimeCount then
        return true
      end
    end

    return false
  end

  ---Calculate timer time
  ---@param timer number
  ---@return integer
  ---@private
  function obj:getCurrentTimerTime(timer)
    return math.floor(computer.uptime() - timer)
  end

  ---Get craft remained time
  ---@return integer
  ---@private
  function obj:getCraftTimeRemained()
    local craftTime = self.controllerProxy.getWorkProgress() / 20
    local maxCraftTime = self.controllerProxy.getWorkMaxProgress() / 20

    return maxCraftTime - craftTime
  end

  ---Get stability remained time
  ---@private
  ---@return integer
  function obj:getStabilityTimeRemained()
    return (95 + 30 * self.maxCyclesCount) - self.stateMachine.data.currentTimer
  end

  ---Calculates space time consumption per cycle
  ---@param cycle integer
  ---@param time? integer
  ---@return integer
  ---@private
  function obj:calculateSpaceTimeByCycleCount(cycle, time)
    time = time or 30

    return math.ceil(time * 2 ^ (cycle - 1))
  end

  ---Calculates space time consumption for cycles
  ---@param cycles integer
  ---@param startCycle? integer
  ---@return integer
  ---@private
  function obj:calculateSpaceTimeCount(cycles, startCycle)
    startCycle = (startCycle ~= nil and startCycle ~= 0) and startCycle or 1

    local count = 0

    for i = startCycle, cycles, 1 do
      count = count + self:calculateSpaceTimeByCycleCount(i)
    end

    return math.ceil(count)
  end

  ---Encode fake pattern
  ---@param spaceTimeCount number
  ---@return integer
  ---@private
  function obj:encodePattern(spaceTimeCount)
    local requests = 1

    local a = spaceTimeCount

    while spaceTimeCount > 2000000000 do
      spaceTimeCount = math.ceil(spaceTimeCount / 2)
      requests = requests * 2
    end

    if (spaceTimeCount * requests) ~= a then
      event.push("log_debug", "Too much: "..numWithCommas((spaceTimeCount * requests) - a).." / "..numWithCommas(a).." / "..numWithCommas(spaceTimeCount * requests));
    end

    self.meInterfaceProxy.setInterfacePatternInput(1, 2, self.database.address, 2, spaceTimeCount)

    return requests
  end

  ---Request fake pattern
  ---@param requestCount integer
  ---@private
  function obj:requestFakeRecipe(requestCount)
    local craftables = obj.meInterfaceProxy.getCraftables({label = self.fakeRecipeName})
    local recipe = craftables and craftables[1]

    if recipe == nil then
      event.push("log_warning", "requestFakeRecipe: '"..self.fakeRecipeName.."' not found in craftables (pattern may be invalid)")
      return false
    end

    local craft = recipe.request(requestCount)

    while craft.isComputing() == true do
      os.sleep(0.1)
    end

    return craft.hasFailed() == false
  end

  ---Try cancel craft of the faker pattern
  ---@private
  function obj:tryCancelFakeRecipe()
    local cpus = self.meInterfaceProxy.getCpus()

    for _, value in pairs(cpus) do
      if value.cpu.isBusy() == true then
        local output = value.cpu.finalOutput()

        if output == nil then
          return false
        end

        if output.label == self.fakeRecipeName then
          local isCanceled = value.cpu.cancel()
          return isCanceled
        end
      end
    end

    return true
  end

  ---Remove Excess Spacetime from black hole.
  ---Transfers the storage drive from the ME Drive side into the IO Port,
  ---waits for it to appear in slot 1 of the IO Port output side (as seen
  ---from the transposer), then transfers it back.
  ---@private
  function obj:removeExcessSpacetime()
    local transferred = self.ioPortTransposer.transferItem(self.meDriveSide, self.meIoPortSide, 1)

    if transferred == 0 then
      return
    end

    local timeout = computer.uptime() + 10
    while self.ioPortTransposer.getSlotStackSize(self.meIoPortSide, 1) ~= 1 do
      if computer.uptime() > timeout then
        event.push("log_warning", "removeExcessSpacetime timed out waiting for item in IO port slot 1")
        return
      end
      os.sleep(0.1)
    end

    self.ioPortTransposer.transferItem(self.meIoPortSide, self.meDriveSide, 1)
  end

  ---Check if craft of the fake pattern is active on any CPU
  ---@private
  function obj:hasFakeRecipe()
    local cpus = self.meInterfaceProxy.getCpus()

    for _, value in pairs(cpus) do
      if value.cpu.isBusy() == true then
        local output = value.cpu.finalOutput()

        if output ~= nil and output.label == self.fakeRecipeName then
          return true
        end
      end
    end

    return false
  end

  ---Put seed to open black hole
  ---@private
  function obj:openBlackHole()
    self.blackHoleSeedsTransposerProxy.transferItem(
      self.transposerItems["Black Hole Seed"].side,
      self.blackHoleSeedInputBusSide,
      1,
      self.transposerItems["Black Hole Seed"].slot)
  end

  ---Put seed to collapse black hole
  ---@private
  function obj:collapseBlackHole()
    self.blackHoleSeedsTransposerProxy.transferItem(
      self.transposerItems["Black Hole Collapser"].side,
      self.blackHoleSeedInputBusSide,
      1,
      self.transposerItems["Black Hole Collapser"].slot)
  end

  setmetatable(obj, self)
  self.__index = self
  return obj
end

return blackHoleController
