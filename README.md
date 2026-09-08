## **Played Plus**

A World of Warcraft: Classic (Anniversary, Seasons, Hardcore, Era) addon that expands /played into a visual history of how you spent your time and earned your experience.

Played Plus tracks time played by level and day, records your leveling activity, and classifies the XP you earn so you can see how much came from kills, quests, dungeon kills, exploration, and other sources. It also keeps an account-wide view of lifetime /played for characters and realms the addon has seen.

Instead of only answering _how long have I played?_, Played Plus helps answer _what did I do with that time?_

### **Features**

*   **Level History** - See time played, XP progress, quests completed, kill count, and dungeons completed per level (while tracked by Played Plus - progress prior to installing Played Plus is uknown).
*   **XP Tracking** - Breaks earned XP into Kills, Quests, Dungeon, and Other classifications.
*   **XP Visualized** - A color-coded bar shows level progress and where your earned XP came from.
*   **XP History** - Review tracked playtime by date, class, and character on the current realm.
*   **Account /played** - View lifetime /played totals by class across all characters on the current realm.
*   **Character Details** - Hover account totals to see the individual characters, levels, and playtime.
*   **XP Log** - An XP transaction history to inspect individual gains and their classifications.
*   **XP Interface** - A compact interface to navigate and view all of the above.
*   **Configurable -** Control opacity, labels, tooltips, detail columns, and status information from the Blizzard AddOns settings.

### **XP Tracking**

Played Plus observes XP gained while the addon is running and records each XP increase as a transaction. Source information is then used to classify that XP without changing the amount actually earned.

This lets the Level History show not only how quickly you leveled, but how you earned the XP that got you there.

XP is displayed in four categories:

*   **Kills** - XP earned from world enemies
*   **Quests** - XP awarded from quest turn-ins
*   **Dungeon** - XP earned from enemies inside dungeons
*   **Other** - Infrequent XP or XP that cannot accurately be classified

### **Account Tracking**

Played Plus stores account-wide information for characters it has seen and uses Blizzard's /played data to build lifetime playtime totals. 

**Daily History** records playtime tracked by Played Plus while you play. **Account /played** uses Blizzard's authoritative lifetime /played total for each character when that character is logged in.

### **Commands**

*   /pp - Open Played Plus
*   /pp options - Open addon settings
*   /pp today - Show today's tracked statistics
*   /pp level - Show current-level statistics
*   /pp levels - Show recent level history
*   /pp account - Open account-wide lifetime /played
*   /pp dungeon - Manually record a dungeon completion
*   /pp sync - Request a fresh /played total
*   /pp xplog \[number|all\] - Show XP transaction history
*   /pp debugxp - Toggle live XP debug logging

### **Notes**

Played Plus can only record XP and daily activity while the addon is installed and running. Existing /played totals can be captured when a character logs in, but Blizzard does not expose a character's historical XP sources or day-by-day playtime.

Updated, uploaded, and maintained (at least for now) by [StormtrooperTK421](https://www.curseforge.com/members/stormtroopertk421) on [GitHub](https://github.com/DustinChecketts/PlayedPlus). Please submit issues and I'll do my best to troubleshoot, replicate, and resolve issues as my limited abilities allow.
