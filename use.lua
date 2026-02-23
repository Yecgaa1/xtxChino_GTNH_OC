robot_api = require("robot")
component = require("component")
while true do
  component.inventory_controller.equip()
  os.sleep(0.1)
  robot_api.use()
  component.inventory_controller.equip()
end
