# Physical setup

## Everything should be on the same network
Because of CC networking rules, both of these setups will NOT work for transferring items between chests:
<img src="https://github.com/user-attachments/assets/24611491-9abe-46ea-a71a-81df4c19c39c" width="800">

For a refresher of those rules, refer to the following cheatsheet. The red, green and blue lines each mark a separate network, and transfer is only possible if the source and destination chests are on the same network.
<img src="https://github.com/user-attachments/assets/9d8f0abf-d7fc-4bd4-a57e-a2ccf82e760e" width="800">

## No double modems
DO NOT connect the same chest two or more times to the same network via multiple modems (as shown below). This will make the one chest appear as two chests and will throw off all internal logic.  
<img src="https://github.com/user-attachments/assets/b99df924-6998-40dd-a1c5-c99b485e650b" width="800">

Connecting the same chest to multiple networks is perfectly okay though, and is the de facto method for transferring items between networks (as shown below)  
<img src="https://github.com/user-attachments/assets/8f8d40e7-17a0-4fdd-89ca-e1d1c104fa02" width="800">

## Turtles should manage their own inventory

Because of api quirks, only a turtle is capable of `.list()`-ing its own inventory, and therefore any logistics code that wants to transfer to and from the turtle must run on said turtle. (use the `self` peripheral name to achieve that through hopper.lua)
Additionally, the only fast way to transport items to and from the turtle is via a modem, so you should use wired modems for turtle item logistics whenever possible, and at all times when using hopper.lua (`turtle.suck` and `turtle.drop` are just not supported)

If you have a recent enough version of the UnlimitedPeripheralWorks mod installed, the above does not apply as that mod makes all turtles wrappable as inventories. (You should still use wired modems if you're using `self`, though)

## Create integrations

On Fabric you need UnlimitedPeripheralWorks installed, on Forge it works without addons but you need to use `-to-slot 1` when inserting into blocks like the depot and the crushing wheel controller.

## AE2 integrations

On Forge you need to use the ME Bridge from Advanced Peripherals.
On Fabric you need UnlimitedPeripheralWorks installed and to connect a wired modem to any energy cell on the network. (yes, an energy cell)
