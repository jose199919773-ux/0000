--test 


--- Main
function main()
  while true do
	wait(40)
	if isKeyDown(17) and isKeyDown(82) then -- CTRL+R
		while isKeyDown(17) and isKeyDown(82) do wait(80) end
		reloadScripts()
	end
  end
end
