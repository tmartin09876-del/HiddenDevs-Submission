-- Defining useful services

local RunService = game:GetService("RunService")
local PlayerService = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Events = ReplicatedStorage.Events

-- Defining customizable variables I may want to change later

local gridSize = Vector3.new(4, 0, 4)
local roomSize = Vector3.new(20, 0, 20)
local tickSpeed = 2
local pathsGenerated = 3
local enemiesGenerated = 2

-- Used for raycasting wall checks later

local wallOffsets = {
	Vector3.new((roomSize.X / 2), 5, 0);
	Vector3.new(0, 5, (roomSize.Z / 2));
	Vector3.new(-(roomSize.X / 2), 5, 0);
	Vector3.new(0, 5, -(roomSize.Z / 2));
}

local floor = workspace.Baseplate
local lastTick = tick()
local tickInputs = {}
local enemies = {}

-- Made this function so I don't have to repeat code creating parts

local function BuildWall(size: Vector3)
	local wall = Instance.new("Part")
	wall.Anchored = true
	wall.Name = "Wall"
	wall.Parent = workspace.Walls
	wall.Size = size
	return wall
end

-- Same as BuildWall function

local function CreateEnemy(position: Vector3)
	local enemy = Instance.new("Part")
	enemy.Anchored = true
	enemy.Name = "Enemy"
	enemy.Parent = workspace.Characters
	enemy.Size = Vector3.new(2, 2, 2)
	enemy.CanCollide = false
	enemy.Color = Color3.fromRGB(255, 0, 0)
	enemy.Material = Enum.Material.Neon
	enemy.Position = position
	local GridPosition = Instance.new("Vector3Value", enemy)
	GridPosition.Name = "GridPosition"
	GridPosition.Value = position
	table.insert(enemies, enemy)
end

-- Function for checking what is around a grid space

local function GetNeighbors(pos)
	-- Creating a table for the positions I want to check relative to the grid space (right, left, foward, backward)
	local neighbors = {
		pos + Vector3.new(gridSize.X, 0, 0),
		pos + Vector3.new(-gridSize.X, 0, 0),
		pos + Vector3.new(0, 0, gridSize.Z),
		pos + Vector3.new(0, 0, -gridSize.Z)
	}

	local validNeighbors = {}
	-- Looping through the positions for checks
	for _, neighbor in neighbors do
		local direction = neighbor - pos
		-- Raycasting for the check
		local ray = workspace:Raycast(pos + Vector3.new(0, 2, 0), direction)

		if not ray then
			-- If we don't hit anything, then the space is empty and it is safe to add it to the table of valid spaces
			table.insert(validNeighbors, neighbor)
		end
	end
	-- Returning the safe spaces we found
	return validNeighbors
end

-- Function for finding the shortest path to target for enemy AI
local function GetPath(startPos, targetPos)
	local open = {startPos} -- List of positions to check
	local paths = {} -- Paths found
	
	local g = {} -- Distance from the start
	local f = {} -- Distance from start + goal (used for determining which is the best route to take)

	-- Storing our starting values
	local startKey = math.round(startPos.X) .. "," .. math.round(startPos.Z)
	g[startKey] = 0
	f[startKey] = (startPos - targetPos).Magnitude
	
	for i = 1, 200 do -- Limiting it to check 200 grid spaces for performance
		if #open == 0 then break end -- If there are no more spaces then don't unnessecarily keep running the loop (more performance)
	
		local current = open[1]
		local currentIdx = 1
		-- Finding the next best space by checking which has the lowest f value
		for index, node in open do
			local nodeKey = math.round(node.X) .. "," .. math.round(node.Z)
			if f[nodeKey] < f[math.round(current.X) .. "," .. math.round(current.Z)] then
				current = node
				currentIdx = index
			end
		end

		-- Checking if we're at our target position yet
		if (current - targetPos).Magnitude < (gridSize.X + 1) then
			local finalPath = {}
			local backtrace = current
			while backtrace do
				local key = math.round(backtrace.X) .. "," .. math.round(backtrace.Z)
				table.insert(finalPath, 1, backtrace)
				backtrace = paths[key]
				if backtrace == startPos then break end
			end
			return finalPath
		end

		-- Removing the space we just found from the table of spaces we haven't explored
		table.remove(open, currentIdx)

		-- Used for checking all 4 directions once again
		local sides = {
			current + Vector3.new(gridSize.X, 0, 0),
			current + Vector3.new(-gridSize.X, 0, 0),
			current + Vector3.new(0, 0, gridSize.X),
			current + Vector3.new(0, 0, -gridSize.X)
		}
		
		for _, nextPos in sides do
			-- Checking if the path to each neighbor is blocked
			if not workspace:Raycast(current + Vector3.new(0, 2, 0), nextPos - current) then
				local nextKey = math.round(nextPos.X) .. "," .. math.round(nextPos.Z)

				-- Calculating the cost of moving to the next space
				local cost = g[math.round(current.X) .. "," .. math.round(current.Z)] + gridSize.X

				-- Checking if we haven't checked this space yet or if there's already a better way to get there that we previously found
				if not g[nextKey] or cost < g[nextKey] then
					paths[nextKey] = current
					g[nextKey] = cost
					f[nextKey] = cost + (nextPos - targetPos).Magnitude -- Updating total

					-- Adding neighbor to open list
					local found = false
					for _, val in open do
						if val == nextPos then found = true break end
					end
					if not found then table.insert(open, nextPos) end
				end
			end
		end
	end
	return nil
end

local function ApplyMovement(enemy, nextPos)
	-- Calculating the difference in positions
	local diff = nextPos - enemy.Position
	local dir = ""

	-- Since we can only move one space at a time, and not diagnally, only x or z will be changed by 4, so we can check if the values are different with each value
	if diff.X > 1 then dir = "right"
	elseif diff.X < -1 then dir = "left"
	elseif diff.Z > 1 then dir = "backward"
	elseif diff.Z < -1 then dir = "forward"
	end

	-- Storing the direction as an input
	if dir ~= "" then
		tickInputs[enemy] = {dir}
	end
end

local function GenerateRooms()
	-- Generating usually takes a few seconds, so we let clients know that we're generating a maze for them
	Events.ChangeText:FireAllClients("Generating...")
	-- Clean up from whatever was there before
	workspace.Walls:ClearAllChildren()

	-- Same here
	for _, enemy: BasePart in workspace.Characters:GetChildren() do
		if enemy.Name == "Enemy" then
			enemy:Destroy()
		end
	end

	-- Setting the spawn and end locations
	workspace.SpawnLocation.Position = floor.Position - Vector3.new(floor.Size.X / 2, -floor.Size.Y / 2, floor.Size.Z / 2) + roomSize / 2
	
	local startPosition = workspace.SpawnLocation.Position - Vector3.new(0, 1, 0)
	local endPosition = startPosition + (workspace.Baseplate.Size * Vector3.new(1, 0, 1)) - roomSize
	workspace.WinPad.Position = endPosition + Vector3.new(0, 3, 0)

	for i = 1, (floor.Size.X / roomSize.X), 1 do -- Looping through columns of rooms
		for p = 1, (floor.Size.Z / roomSize.Z), 1 do -- Looping through each room in each column
			local roomPosition = startPosition + Vector3.new((i - 1) * roomSize.X, 0, (p - 1) * roomSize.Z) -- Getting the position of the current iteration by multiplying the room size by number of columns and rooms (i and p)
			local doors = 0
			local wall: BasePart
			
			repeat
				for s, offset in wallOffsets do -- To check every neighbor
					if s == 2 or s == 4 then -- Building wall vertically or horizontally depending on the position relative to the space it will be placed (could rotate the wall alternatively)
						wall = BuildWall(Vector3.new(roomSize.X, 10, 1))
					else
						wall = BuildWall(Vector3.new(1, 10, roomSize.Z))
					end

					wall.CFrame = CFrame.new(roomPosition + offset)

					-- Other logic could be used here, but I calculated it using trigonometry
					-- I'm getting the adjacent side length of a right triangle using the distance between the center of the floor and the point we want to create a door in order to check if it's
					-- less than half the length of the floor. This is to check if it is an outer wall, and if it is then we don't want a door there because they will fall out of the world. Using the
					-- distance between the floor and the wall position itself doesn't work because the length is longer diagnolly than horizontally. If the floor were a circle then it would work.
					local hyp = (floor.Position - (roomPosition + offset)).Magnitude
					local opp = (floor.Position.Z - (roomPosition + offset).Z)
					local rad = math.asin(opp/hyp) -- Getting angle in radians
					local adj1 = hyp * math.cos(rad) -- Calculating adjacent length

					opp = (floor.Position.X - (roomPosition + offset).X) -- Have to do it a second time because we can't ignore the other dimension, otherwise we are only checking if it's a wall on the outside
					-- on the z axis and completely ignoring if it is on the x axis.
					rad = math.asin(opp/hyp)
					local adj2 = hyp * math.cos(rad)

					if adj1 < floor.Size.X / 2 and adj2 < floor.Size.X / 2 then -- Check if it's an outside wall
						if math.random(1, 3) == 1 and doors < 3 then -- 1/3 chance for it to be a door
							for _, wall: BasePart in workspace.Walls:GetChildren() do
								if wall.Position == roomPosition + offset then -- Finding the right part
									-- Make it into a door
									wall.Size = Vector3.new(wall.Size.X, 2, wall.Size.Z)
									wall.Position += Vector3.new(0, 4, 0)
								end
							end
							doors += 1
						end
					end
				end
				task.wait() -- Performance (Don't wanna crash the game)
			until doors > 0 -- Want at least one door so most spaces are accessible
		end
	end
	
	local foundExit = false
	local searches = 0
	local visited = {}

	-- Function to check if the maze is even possible
	local function searchRoom(roomPosition: Vector3)
		if visited[tostring(roomPosition)] then return end -- If already checked then return
		
		visited[tostring(roomPosition)] = true
		
		if roomPosition == startPosition then
			searches = 0
		end
		
		searches += 1
		
		if roomPosition == endPosition then
			foundExit = true
			return
		end -- If we found the exit then we were successful and can return
		
		for i, offset in wallOffsets do
			if i < 3 then -- Only have to check up and right for other spaces logically (performance)
				local foundWall = false
				
				if workspace:Raycast(roomPosition, (offset * Vector3.new(1, 0, 1))) then
					foundWall = true
				end

				if not foundWall and (floor.Position - roomPosition).Magnitude < floor.Size.X  and searches < 50 then -- If we don't find a wall and were still inside of the maze then it's an open space and we can search it
					-- (Keep it less than 50 searches for performance)
					searchRoom(roomPosition + Vector3.new(offset.X * 2, 0, offset.Z * 2))
				end
			end
		end
	end
	
	searchRoom(startPosition) -- Start the search
	
	if not foundExit then
		task.wait()
		GenerateRooms() -- If we don't find an exit then regenerate the maze
	else
		Events.Ticks.Value = 0
		
		for i = 1, enemiesGenerated, 1 do
			-- Generating a random room for the enemy to spawn in, then spawning them there (minimum 3 so they aren't too close to the player)
			local numberOfColumns = (floor.Size.X / roomSize.X)
			local pos = startPosition + Vector3.new(roomSize.X * (math.random(3, numberOfColumns) - 1), 3, (roomSize.Z * (math.random(3, numberOfColumns) - 1)))
			CreateEnemy(pos)
		end
		
		Events.GameStarted:FireAllClients()
	end
end

local function OnCharacterAdded(character: Model)
	-- Setting up character
	character.Parent = workspace.Characters
	local hrp: Part = character:WaitForChild("HumanoidRootPart")
	hrp.Anchored = true
	hrp.CFrame = workspace.SpawnLocation.CFrame + Vector3.new(0, 3, 0)
	local gridPosition = Instance.new("Vector3Value", character)
	gridPosition.Name = "GridPosition"
	gridPosition.Value = hrp.Position
end

local function OnPlayerJoin(player: Player)
	-- Setting up player
	player.CharacterAdded:Connect(function(character: Model)
		OnCharacterAdded(character)
	end)
end

local moveTI = TweenInfo.new((1 / tickSpeed) - ((1 / tickSpeed) / 10), Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)

RunService.Heartbeat:Connect(function()
	if tick() >= lastTick + (1 / tickSpeed) then
		lastTick = tick()
		Events.Ticks.Value += 1
		-- Ticking however many times per second
		
		for char: Model, tickData in tickInputs do
			local hrp: Part = char:FindFirstChild("HumanoidRootPart") or char
			
			if char and hrp then
				-- Doing every action that was stored in the last tick
				for _, input in tickData do
					if input == "right" then
						char.GridPosition.Value += hrp.CFrame.RightVector * gridSize.X
						tickInputs[char] = {"inAction"}
					elseif input == "left" then
						char.GridPosition.Value -= hrp.CFrame.RightVector * gridSize.X
						tickInputs[char] = {"inAction"}
					elseif input == "forward" then
						char.GridPosition.Value += hrp.CFrame.LookVector * gridSize.X
						tickInputs[char] = {"inAction"}
					elseif input == "backward" then
						char.GridPosition.Value -= hrp.CFrame.LookVector * gridSize.X
						tickInputs[char] = {"inAction"}
					elseif input == "inAction" then -- Characters can't move with they're already in action, so they can only move every other tick, this is serving as a debounce
						table.remove(tickInputs[char], table.find(tickInputs[char], "inAction"))
					end
				end
				
				if char:FindFirstChild("GridPosition") then -- Tweening the character to their next position
					TweenService:Create(
						hrp,
						moveTI,
						{Position = char.GridPosition.Value}
					):Play()
				end
			end
		end
		
		for _, enemy: BasePart in enemies do
			for _, target: Player in PlayerService:GetPlayers() do -- 1 player max servers, so this is just finding the target
				if target and target.Character and target.Character:FindFirstChild("HumanoidRootPart") then
					target = target.Character.HumanoidRootPart
					
					if tickInputs[enemy] and table.find(tickInputs[enemy], "inAction") then -- If the enemy is in action then they are unable to move
						return
					end
					
					if math.random(1, 10) <= 3 then -- To make the AI a little dumber, they forget to move a space 30% of the time
						continue 
					end

					local rayToPlayer = workspace:Raycast(enemy.Position, (target.Position - enemy.Position)) -- Checking if they can see the player to move directly towards then
					local canSeePlayer = (rayToPlayer and rayToPlayer.Instance:IsDescendantOf(target.Parent))

					if canSeePlayer then -- Move towards player if it can see them
						local path = GetPath(enemy.Position, target.Position)
						if path and #path > 0 then
							local nextStep = path[1]
							ApplyMovement(enemy, nextStep)
						end
					else -- If they can't see the player
						if math.random(1, 2) == 1 then -- 50% chance
							local neighbors = GetNeighbors(enemy.Position)
							local validMove = neighbors[math.random(1, #neighbors)]

							if not workspace:Raycast(enemy.Position, (validMove - enemy.Position)) then -- Check if the space is free
								ApplyMovement(enemy, validMove)
							end
						end
					end
				end
			end
			
			for _, part: BasePart in workspace:GetPartBoundsInRadius(enemy.Position, gridSize.X * .8) do -- Check if there's a player in any of the srrounding squares
				local player = PlayerService:GetPlayerFromCharacter(part.Parent)
				if player then -- Kill the player
					player.Character:Destroy()
					player:LoadCharacterAsync()
				end
			end
			
			for _, part: BasePart in workspace:GetPartBoundsInRadius(workspace.WinPad.Position, gridSize.X * .8) do -- Check if a player is on the win part
				local player = PlayerService:GetPlayerFromCharacter(part.Parent)
				if player then -- Reset the player, regenerate the maze since they won
					player.Character:Destroy()
					player:LoadCharacterAsync()
					GenerateRooms()
				end
			end
		end
	end
end)

Events.Move.OnServerInvoke = function(player: Player, direction: string) -- Player input happened for moving
	local char: Model = player.Character
	
	if char then
		local hrp: BasePart = char:WaitForChild("HumanoidRootPart")
		
		if not tickInputs[char] then
			tickInputs[char] = {}
		end
		
		for _, input in tickInputs[char] do -- Get rid of any other movements if they're already there (there should only be one at once, they can only move one square at once)
			if input == "forward" or input == "backward" or input == "right" or input == "left" then
				table.remove(tickInputs[char], table.find(tickInputs[char], direction))
			end
		end
		
		local directionVal
		
		if direction == "forward" then
			directionVal = hrp.CFrame.LookVector * gridSize.X
		elseif direction == "backward" then
			directionVal = -hrp.CFrame.LookVector * gridSize.X
		elseif direction == "right" then
			directionVal = hrp.CFrame.RightVector * gridSize.X
		elseif direction == "left" then
			directionVal = -hrp.CFrame.RightVector * gridSize.X
		end
		
		if directionVal and not workspace:Raycast(char.GridPosition.Value, directionVal) then -- Check if the space is free
			table.insert(tickInputs[char], direction) -- Store the input for when the tick happens to execute it
			return directionVal -- Return it to the client so they know where to preview the space (would be unessecary, but I'm storing customizable variables here instead of in a odule)
		end
	end
end

for _, player: Player in PlayerService:GetPlayers() do -- Since this is later in the script, the first player may load faster than the server can start checking for players to join, so this
-- is a safety precaution
	OnPlayerJoin(player) -- Connect function to event
	
	if player.Character then -- Safety precaution in case character has loaded already
		OnCharacterAdded(player.Character) -- Same
	end
end

PlayerService.PlayerAdded:Connect(function(player: Player)
	OnPlayerJoin(player)
end)

GenerateRooms() -- Start generation
