Set sh = CreateObject("WScript.Shell")
sh.CurrentDirectory = "C:\Users\micha\Projects\sticky"
sh.Run "cmd /c npm run start", 0, False
