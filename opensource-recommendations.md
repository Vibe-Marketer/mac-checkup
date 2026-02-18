Yes, there are excellent open-source and free, community-standard tools available for macOS that allow you to monitor MacBook battery health, charge cycles, and real-time charging information. 
Here are the top options that meet your requirements:
1. Powerflow (Open Source)
Powerflow is a modern, open-source macOS app specifically designed to monitor power usage, including real-time charging details. 
Reddit
Reddit
What it does: Provides deep insights into power consumption (screen, System on Chip), tracks charger input power, and gives a breakdown of power delivered to the battery.
Best for: Real-time diagnostics of what is coming into the machine vs. what is being consumed. 
Reddit
Reddit
 +3
2. Battery-Toolkit (Open Source)
This is a powerful open-source tool for advanced battery management, designed for Apple Silicon Macs, but it works on older models too. 
GitHub
GitHub
 +3
What it does: It allows for viewing detailed battery status, managing charge limits to prevent degradation, and monitoring the overall state of the battery.
Best for: Users who want to see raw battery data and take control of charging thresholds. 
GitHub
GitHub
 +4
3. CoconutBattery (Free/Freeware)
While not technically "open source" (it is freeware), this is the industry-standard, free tool that almost all Mac users use to check battery health and degradation. 
coconutBattery
coconutBattery
 +2
What it does: Shows current charge, maximum capacity (degradation), cycle count, and even the manufacturer date of the battery.
Best for: An immediate, comprehensive, and easy-to-read "medical chart" of your battery. 
Stack Exchange
Stack Exchange
 +4
4. pmset (Built-in Terminal Command) 
If you want a native solution without downloading third-party software, you can use the command line.
How to: Open Terminal and type: pmset -g batt
What it shows: Current charge percentage, whether it is plugged in/charging, and if the battery is "Normal" or needs service. 
Hexnode
Hexnode
 +1
Summary of Features
Tool 	Open Source?	Best Feature
Powerflow	Yes	Real-time charging data & power consumption
Battery-Toolkit	Yes	Advanced monitoring & charging limits
CoconutBattery	No (Freeware)	Detailed degradation/capacity history
How to Check for Battery Degradation
Using CoconutBattery or Powerflow, you can look at the Maximum Capacity compared to the Design Capacity. If your MacBook is 2 years old and the maximum capacity is below 80%, it has significant degradation. A "Service Recommended" status in macOS Settings also confirms a degraded battery.
